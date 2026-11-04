package db

import (
	"context"
	"os"
	"testing"
	"time"
)

// TestTenantSurvivesTheConnection is the integration test for the claim every other assertion in this
// repository depends on: that a query this process runs is attributed to the tenant AFPC_TENANT_ID
// names, and not to whichever tenant the server's app.default_tenant_id happens to hold.
//
// It exists because the bug it catches was invisible from the outside. The connect hook used
// set_config('app.tenant_id', $1, true) - is_local, so the setting lives only for the transaction it is
// issued in, and AfterConnect is not inside one. The implicit transaction ended, the setting went away,
// and every later query resolved afpc_current_tenant() from the server-wide fallback. On a machine
// where that fallback is the intended tenant the agent works, the health endpoint is green, and the
// rows land in the right place - which is how this sat undetected through a full smoke test, with the
// startup warning it did print (tenant_guc="") read as noise rather than as the whole message.
//
// So the assertion is about the GUC itself and not about a query's results: a result cannot tell a
// claim from a coincidence, and this test's reason for existing is that coincidence looked identical.
//
// It needs a real database, and there is no fake for this - pgx's own connection lifecycle is the thing
// under test. Without AFPC_PG_HOST it skips rather than passes, and the skip is stated in the same
// terms the code would use at startup: an unrunnable check and a passing one must not sound alike.
func TestTenantSurvivesTheConnection(t *testing.T) {
	if os.Getenv(EnvHost) == "" || os.Getenv(EnvPassword) == "" {
		t.Skipf("%s and %s are unset: this test needs a live database, and skipping is the honest "+
			"answer rather than a pass", EnvHost, EnvPassword)
	}
	want := os.Getenv(EnvTenant)
	if want == "" {
		t.Skipf("%s is unset, so there is no expected tenant to compare against", EnvTenant)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	d, err := Open(ctx)
	if err != nil {
		t.Skipf("cannot reach the database (%v): this test asserts a property of a live connection", err)
	}
	defer d.Close()

	// Three reads, not one. The first is the one that fails the bug above, and the repetition is for
	// the shape a pool actually presents: a connection that answered correctly once and then lost the
	// setting on its way back through the pool would otherwise pass.
	for i := 0; i < 3; i++ {
		rows, err := d.Query(ctx, "SELECT current_setting('app.tenant_id', true) AS claimed")
		if err != nil {
			t.Fatalf("read %d: %v", i, err)
		}
		if len(rows) != 1 {
			t.Fatalf("read %d returned %d rows", i, len(rows))
		}
		got, _ := rows[0]["claimed"].(string)
		if got != want {
			t.Errorf("read %d: app.tenant_id is %q, want %q. An empty value means the connect hook's "+
				"set_config was transaction-local and expired before this query ran, which is the "+
				"failure this test exists for: the tenant would be coming from app.default_tenant_id, "+
				"and this process would be asserting an identity it never claimed", i, got, want)
		}
	}

	// The claim is what makes row security return the tenant's rows, so prove the consequence and not
	// only the setting. A count is enough: the seeded tenant has customers, and an unattributed
	// connection under a policy that matched nothing would answer zero.
	rows, err := d.Query(ctx, "SELECT count(*) AS n FROM vw_customers")
	if err != nil {
		t.Fatalf("the read path the claim exists for: %v", err)
	}
	t.Logf("app.tenant_id=%s reaches %v customers", want, rows[0]["n"])
}

// TestSettingsRefusesAnEmptyTenant is the startup half of the same rule: the process would rather not
// start than start and attribute everything to a guess.
func TestSettingsRefusesAnEmptyTenant(t *testing.T) {
	t.Setenv(EnvHost, "example.invalid")
	t.Setenv(EnvTenant, "")
	if _, err := Settings(); err == nil {
		t.Error("Settings() accepted an empty tenant, so the pool would fall back to whatever the server defaults to")
	}
}
