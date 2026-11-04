// Package db is the customer service agent's connection to the Agent First ERP CRM database.
//
// Two facts about this deployment shape everything here, and both are consequences of how the
// server is configured rather than choices this package made:
//
//   - TLS is required for every network connection (pg_hba is hostssl-only with a plaintext
//     reject), and the leaf certificate carries IP subjectAltNames only - 127.0.0.1, the LAN
//     address, the tailnet address. So sslmode=verify-full validates when the host is named by
//     one of those addresses and fails when it is named by a DNS name, including the container
//     hostname. Pointing this at "afpc-pg" would be more legible and would not verify.
//   - Row security binds a role, not a schema, and the tenant is resolved per connection from
//     app.tenant_id. DATABASE_REVIEW.md 2.3's complaint about the original schema was that the
//     GUC existed and nothing set it, so policies filtered to nothing or to a fallback. Setting
//     it here, in the pool's AfterConnect, is the half of that finding that could not be closed
//     in SQL.
package db

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Environment names. AFPC_ is the prefix the database tooling already uses (scripts/db/_common.sh
// reads dev/.env, which defines AFPC_TENANT_ID and the role passwords), so the agent and the
// migration harness read the same facts from the same place.
const (
	EnvHost     = "AFPC_PG_HOST"
	EnvPort     = "AFPC_PG_PORT"
	EnvDatabase = "AFPC_PG_DB"
	EnvUser     = "AFPC_PG_USER"
	EnvPassword = "AFPC_PG_PASSWORD"
	EnvTenant   = "AFPC_TENANT_ID"
	EnvSSLMode  = "AFPC_PG_SSLMODE"
	EnvRootCert = "AFPC_PG_SSLROOTCERT"
	EnvAppName  = "AFPC_PG_APPNAME"
)

// Defaults are the values dev/README documents for this server. The host default is an address
// and not a hostname, for the certificate reason above.
const (
	defaultHost    = "127.0.0.1"
	defaultPort    = "5432"
	defaultDB      = "agent_first_erp_crm"
	defaultUser    = "afpc_app"
	defaultSSLMode = "verify-full"
	defaultApp     = "jada-customer-service"
)

var (
	// ErrDisabled reports that no database was configured. It is deliberately not fatal at
	// startup: the agent may serve its non-CRM tools, and /api/health says so in one field.
	// Refusing to boot would take the UI down for a database a reader can already see is absent.
	ErrDisabled = errors.New("database not configured")

	// ErrNoTenant is refused rather than defaulted. init.sh mirrors app.default_tenant_id into
	// the server with ALTER SYSTEM, so a connection with no GUC still lands somewhere - on a
	// single-tenant box always in the developer's tenant, and on a multi-tenant one in whichever
	// tenant the last ALTER SYSTEM named. Letting that happen quietly is the thing review 2.3
	// asked this code to stop doing.
	ErrNoTenant = errors.New(EnvTenant + " is not set")
)

// DB is a pool plus the two facts every request needs: which tenant it speaks for, and how to
// describe the connection in a log line without printing a password.
type DB struct {
	pool      *pgxpool.Pool
	tenantID  string
	host      string
	port      string
	database  string
	user      string
	sslMode   string
	rootCert  string
	appName   string
	safe      string
	createdAt time.Time
}

// Settings reads the environment without connecting.
func Settings() (*DB, error) {
	host := strings.TrimSpace(os.Getenv(EnvHost))
	if host == "" {
		return nil, ErrDisabled
	}
	tenant := strings.TrimSpace(os.Getenv(EnvTenant))
	if tenant == "" {
		return nil, ErrNoTenant
	}

	d := &DB{
		tenantID: tenant,
		host:     host,
		port:     first(os.Getenv(EnvPort), defaultPort),
		database: first(os.Getenv(EnvDatabase), defaultDB),
		user:     first(os.Getenv(EnvUser), defaultUser),
		sslMode:  strings.ToLower(first(os.Getenv(EnvSSLMode), defaultSSLMode)),
		rootCert: strings.TrimSpace(os.Getenv(EnvRootCert)),
		appName:  first(os.Getenv(EnvAppName), defaultApp),
	}

	// The password is never in d.safe. A connection error that names the role is useful in a log;
	// a config dump that repeats the credential is a leak with a stack trace.
	d.safe = fmt.Sprintf("host=%s port=%s dbname=%s user=%s sslmode=%s application_name=%s tenant=%s",
		d.host, d.port, d.database, d.user, d.sslMode, d.appName, d.tenantID)
	if d.rootCert != "" {
		d.safe += " sslrootcert=" + d.rootCert
	}
	return d, nil
}

// Open builds the pool. It does not connect: pgxpool is lazy, and a database that is down when
// the container starts - the normal order when both come up from one compose file - must not take
// the agent down with it. Callers needing a synchronous answer use Ping.
func Open(ctx context.Context) (*DB, error) {
	d, err := Settings()
	if err != nil {
		return nil, err
	}
	if os.Getenv(EnvPassword) == "" {
		return nil, fmt.Errorf("%s is empty: the runtime role cannot connect without it", EnvPassword)
	}

	// ParseConfig on a minimal DSN, then assign the fields. Assembling one string with the
	// password interpolated would make a '%' or '@' in a generated credential fail at connect
	// time with a message about the host, and pgx escapes nothing inside a URL userinfo.
	cfg, err := pgxpool.ParseConfig(fmt.Sprintf("postgres://%s:%s/%s",
		d.host, d.port, d.database))
	if err != nil {
		return nil, fmt.Errorf("parse postgres config: %w", err)
	}
	cfg.ConnConfig.User = d.user
	cfg.ConnConfig.Password = os.Getenv(EnvPassword)
	cfg.ConnConfig.Database = d.database
	cfg.ConnConfig.RuntimeParams["application_name"] = d.appName

	tlsCfg, err := d.tlsConfig()
	if err != nil {
		return nil, err
	}
	cfg.ConnConfig.TLSConfig = tlsCfg

	// Claim the tenant on every new physical connection. set_config as a function call with a
	// parameter, not `SET app.tenant_id = ...`: the value is a uuid, the name contains a dot, and
	// the statement stays identical whatever the tenant is.
	//
	// is_local = false, which is to say session-scoped, and the reason is a bug this line had:
	// with is_local = true the setting belongs to the *transaction*, and AfterConnect runs outside
	// one - so the implicit transaction that carries the SELECT ends immediately, the setting is
	// discarded, and every query the pool later runs on that connection resolves afpc_current_tenant()
	// from app.default_tenant_id instead. On a server where that GUC happens to name the intended
	// tenant - which is true of this development box, which is how the failure stayed invisible -
	// everything works and nothing is claimed. The startup line said so, as a warning nobody had
	// reason to disbelieve.
	//
	// Session scope is safe here for a reason worth stating: this process serves one tenant, resolved
	// once from AFPC_TENANT_ID, so there is no earlier request's tenant for a pooled connection to
	// still be carrying. The worry that made is_local look right applies to a pool shared across
	// tenants, and that process would need more than this flag to be correct: it would have to claim
	// inside each transaction, and set the key on the idempotency claim as well, or a retry could be
	// answered from another tenant's cached result. pkg/db's TestTenantSurvivesTheConnection is the
	// assertion, and it skips when no database is reachable.
	cfg.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
		if _, err := conn.Exec(ctx,
			"SELECT set_config('app.tenant_id', $1, false)", d.tenantID); err != nil {
			return fmt.Errorf("set app.tenant_id on connect: %w", err)
		}
		return nil
	}

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	d.pool = pool
	d.createdAt = time.Now()
	return d, nil
}

// tlsConfig implements the sslmode contract rather than pgx's DSN handling of it, so the
// private-CA case can say what is missing in terms this server actually has.
func (d *DB) tlsConfig() (*tls.Config, error) {
	switch d.sslMode {
	case "disable":
		return nil, nil

	case "require", "prefer", "allow":
		// Encrypts, does not authenticate the peer. dev/README states the difference plainly:
		// this is what to use when the CA was not distributed, and it is not verification.
		return &tls.Config{MinVersion: tls.VersionTLS12, ServerName: d.host,
			InsecureSkipVerify: true}, nil

	case "verify-ca", "verify-full":
		if d.rootCert == "" {
			return nil, fmt.Errorf("sslmode=%s needs %s: the CA is dev/tls/afpc-ca.crt on the "+
				"server, and the leaf is signed by a private authority no system trust store holds",
				d.sslMode, EnvRootCert)
		}
		pem, err := os.ReadFile(d.rootCert)
		if err != nil {
			return nil, fmt.Errorf("read %s=%s: %w", EnvRootCert, d.rootCert, err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("%s=%s contains no parsable certificate", EnvRootCert, d.rootCert)
		}
		cfg := &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: pool, ServerName: d.host}
		if d.sslMode == "verify-ca" {
			// Chain validated against the CA, hostname not compared. This deployment's leaf has
			// IP SANs only, so verify-ca is the mode that works when the host is reached through
			// a name that is not in the certificate - which is a real case here, and the reason
			// both modes are offered rather than one.
			cfg.InsecureSkipVerify = true
			cfg.VerifyPeerCertificate = chainOnly(pool)
		}
		return cfg, nil

	default:
		return nil, fmt.Errorf("unknown %s=%q (want disable, require, verify-ca or verify-full)",
			EnvSSLMode, d.sslMode)
	}
}

// chainOnly verifies the certificate chain while ignoring the name, which is what sslmode=verify-ca
// means in libpq and what tls.Config cannot express directly: setting ServerName and
// InsecureSkipVerify=false checks both.
func chainOnly(root *x509.CertPool) func([][]byte, [][]*x509.Certificate) error {
	return func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
		var certs []*x509.Certificate
		for _, der := range rawCerts {
			c, err := x509.ParseCertificate(der)
			if err != nil {
				return err
			}
			certs = append(certs, c)
		}
		if len(certs) == 0 {
			return errors.New("server presented no certificate")
		}
		inter := x509.NewCertPool()
		for _, c := range certs[1:] {
			inter.AddCert(c)
		}
		_, err := certs[0].Verify(x509.VerifyOptions{
			Roots:         root,
			Intermediates: inter,
			KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
		})
		return err
	}
}

func (d *DB) Pool() *pgxpool.Pool {
	if d == nil {
		return nil
	}
	return d.pool
}

func (d *DB) Tenant() string {
	if d == nil {
		return ""
	}
	return d.tenantID
}

// HostPort, Database and SSLMode are the fields /api/health reports. None of them is secret, and
// none of them is the password - which is not returned by any accessor in this package.
func (d *DB) HostPort() string {
	if d == nil {
		return ""
	}
	return d.host + ":" + d.port
}

func (d *DB) Database() string {
	if d == nil {
		return ""
	}
	return d.database
}

func (d *DB) SSLMode() string {
	if d == nil {
		return ""
	}
	return d.sslMode
}

// String is the form that may be logged.
func (d *DB) String() string {
	if d == nil {
		return "disabled"
	}
	return d.safe
}

// Ping is the synchronous check, with its own deadline so a database that accepts TCP and never
// answers cannot hang a health endpoint.
func (d *DB) Ping(ctx context.Context) error {
	if d == nil || d.pool == nil {
		return ErrDisabled
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return d.pool.Ping(ctx)
}

func (d *DB) Close() {
	if d != nil && d.pool != nil {
		d.pool.Close()
	}
}

// Query is the shape the CRM tools need: call a stored function or a parameterised SELECT, get
// rows back as generic values, render them as JSON for the model.
//
// Decoding into `any` rather than into row structs is deliberate. These rows go to a language
// model, so the Go types only ever get between the data and the JSON; and a tool that returns
// map[string]any survives a view gaining a column the afternoon the view gains it, which is the
// property vw_domain_vocabulary and 0010's register provide on the schema side.
func (d *DB) Query(ctx context.Context, sql string, args ...any) ([]map[string]any, error) {
	if d == nil || d.pool == nil {
		return nil, ErrDisabled
	}
	rows, err := d.pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return collect(rows)
}

// QueryOne is Query for the calls that answer exactly one row, which is every write door:
// add_customer, update_customer, add_communication and save_memory all return one row of
// (success, ids..., message). It returns nil for no rows, not an error - "nothing matched" is an
// answer.
func (d *DB) QueryOne(ctx context.Context, sql string, args ...any) (map[string]any, error) {
	all, err := d.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	if len(all) == 0 {
		return nil, nil
	}
	return all[0], nil
}

// Call invokes a stored function by name with positional parameters. The CRM tools go through
// this rather than open-table SQL, which is ADR-002's rule and 0021's marker-watched one: a
// caller that carries its own INSERT is a rule the database cannot enforce.
//
// A nil in args is passed as a SQL NULL, and a parameter left out entirely would take the
// function's DEFAULT - which is not the same thing on doors where the default is a value
// ('active', 'note'), so the tools name every position.
//
// Names are unqualified and resolve through search_path: afpc_app has
// `ALTER ROLE ... SET search_path = public`, and hard-coding `public.` here would be a second
// statement of where objects live, which is finding 4.5's own complaint about the Python tools.
func (d *DB) Call(ctx context.Context, name string, args []any) ([]map[string]any, error) {
	sql := "SELECT * FROM " + name + "("
	for i := range args {
		if i > 0 {
			sql += ", "
		}
		sql += "$" + itoa(i+1)
	}
	sql += ")"
	return d.Query(ctx, sql, args...)
}

func (d *DB) Exec(ctx context.Context, sql string, args ...any) error {
	if d == nil || d.pool == nil {
		return ErrDisabled
	}
	_, err := d.pool.Exec(ctx, sql, args...)
	return err
}

func first(v, def string) string {
	if strings.TrimSpace(v) == "" {
		return def
	}
	return strings.TrimSpace(v)
}

func itoa(i int) string { return fmt.Sprintf("%d", i) }

// collect turns rows into the generic records every tool renders. It reads the field names off the
// result description rather than from a struct, which is what lets a view gain a column the afternoon
// it gains it without a Go change - the same property vw_domain_vocabulary provides on the schema side.
func collect(rows pgx.Rows) ([]map[string]any, error) {
	desc := rows.FieldDescriptions()
	out := make([]map[string]any, 0, 8)

	for rows.Next() {
		vals, err := rows.Values()
		if err != nil {
			return nil, err
		}
		rec := make(map[string]any, len(desc))
		for i, f := range desc {
			rec[f.Name] = normalise(vals[i])
		}
		out = append(out, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

// normalise turns what pgx decoded into what json.Marshal renders usefully for a model.
//
// Two of these are load-bearing rather than tidy:
//
//   - A time.Time is rendered with its offset. The server writes timestamptz, 0022's whole finding
//     was that a timestamp means different things depending on which clock it came off, and a model
//     that reads "14:02" with no zone cannot tell a four-day-old conversation from a four-hour-old
//     one - which is the difference between a follow-up being due and not being due.
//   - A []byte holding text is decoded rather than passed through, because encoding/json renders
//     every []byte as base64 and the model would read a wall of it where a summary should be.
func normalise(v any) any {
	switch t := v.(type) {
	case nil:
		return nil
	case time.Time:
		if t.IsZero() {
			return nil
		}
		return t.Format(time.RFC3339Nano)
	case time.Duration:
		return t.String()
	case []byte:
		if utf8ish(t) {
			return string(t)
		}
		return t
	case [16]byte:
		// A uuid column, as pgx hands it over when the query's target is `any`: a sixteen-byte
		// *array*, not a slice. json.Marshal renders an array of bytes as a JSON array of sixteen
		// numbers, so every uuid in a tool's output - interaction_id, conversation_id, a memory's id -
		// arrived as [1,161,166,...] and was unquotable by anything reading it back. A caller cannot
		// paste that into a query, which is the entire purpose of the trajectory endpoints.
		//
		// Rendered in the 8-4-4-4-12 form the database itself prints, so the value in a tool's answer
		// is textually identical to the value in psql.
		return fmt.Sprintf("%x-%x-%x-%x-%x", t[0:4], t[4:6], t[6:8], t[8:10], t[10:16])
	case uint64:
		// json.Marshal handles it, but a uint64 above 2^53 cannot be read back exactly by every
		// JSON parser downstream, and pgx produces one for a numeric column it cannot fit in an int64.
		return t
	default:
		return v
	}
}

func utf8ish(b []byte) bool {
	return utf8.Valid(b)
}
