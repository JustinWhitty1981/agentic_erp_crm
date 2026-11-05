#!/usr/bin/env bash
# check_agent_docs.sh - does the documentation still describe the agent that is running?
#
# Why a script and not a review note: `code:agent_docs_match_surface` in scripts/db/_common.sh is a
# scoreboard marker, and a marker that always reports 0 is worse than no marker - it says "watched"
# about something nobody is watching. This file is the watching. It is invoked from
# scripts/db/test-functions.sh through that marker, so a documentation drift fails the same report a
# broken constraint fails, which is the only kind of report anyone reads.
#
# What it checks, and why each one is a real failure rather than a tidiness rule:
#
#   1. every tool the Go backend registers is named in the agent's README, and every tool the README
#      names is registered. A tool in the code but not the docs is a capability nobody knows the agent
#      has; a tool in the docs but not the code is worse, because the system prompt tells the model
#      about a name that answers "not found", which reads to a human as a data problem.
#   2. every environment variable the deployment sets is documented. An undocumented key is a knob
#      that gets changed by accident and a behaviour nobody can reproduce, and AGENTS.md makes
#      environment variables the whole of the configuration story.
#   3. every view the root AGENTS.md advertises exists in the database. This is the check the schema
#      half of this repo has always needed: the table of views in AGENTS.md was written from a
#      superseded SQL file, and two of the rows in it named views that no migration ever created (T4).
#   4. every migration in db/migrations is a row in db/MIGRATIONS.md, and every row in that ledger is a
#      file. The ledger is what tells you which finding a migration closes; when it and the directory
#      disagree, verify.sh's PASS lines credit work that was not done.
#   5. no tool description is empty, and no doc still tells a caller to qualify CRM objects to the
#      schema that 3.1 proved was never created.
#
# Exit status: 0 when the documentation and the surface agree, 1 otherwise. The failure output says
# which file to edit and why, because the point of a watchdog is to be actionable from its own text.

set -uo pipefail

# AFPC_DOCS_ROOT is a test seam, and it exists so scripts/docs/test_check_agent_docs.sh can point the
# text checks at a synthetic tree and prove each one can still fail. A watchdog nobody has seen report a
# failure is indistinguishable from one that cannot.
ROOT="${AFPC_DOCS_ROOT:-}"
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT_DIR="$ROOT/agents/customer_service"
GO_DIR="$AGENT_DIR/backend_go"
# Defined here rather than where it is first read: §1 only sets it inside the "the Go backend exists"
# branch, and §2 uses it in the documented-keys list, so a tree with no backend_go hit an unbound
# variable and stopped - which is how the self-test in test_check_agent_docs.sh found it. The real
# repository always has the backend, and that is exactly why the bug was invisible.
agent_readme="$AGENT_DIR/README.md"
DOC_QUIET=0
[ "${1:-}" = "--quiet" ] && DOC_QUIET=1

fails=0
skips=0

note() { [ "$DOC_QUIET" -eq 1 ] || printf '  %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf '  SKIP %s\n' "$*"; skips=$((skips + 1)); }

say() { [ "$DOC_QUIET" -eq 1 ] || printf '\n== %s ==\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Tools: what the binary registers, from the source
# ---------------------------------------------------------------------------
# Read from the Go source rather than from /api/tools because the check has to run without a server,
# a database, or a model. The registry is a composite literal and its Name: fields are what the agent
# actually advertises; a tool whose name is computed at runtime would not appear here, and the count
# check in section 1c catches that difference rather than assuming it away.
say "1 tools: the code and the README describe one surface"

if [ ! -d "$GO_DIR" ]; then
    skip "no Go backend at $GO_DIR"
else
    code_tools=$(grep -rhoE '^\s*Name:\s*"[a-z0-9_]+"' \
        "$GO_DIR/pkg/tools/tools.go" "$GO_DIR/pkg/crm/tools.go" 2>/dev/null \
        | sed -E 's/.*"([a-z0-9_]+)".*/\1/' | sort -u)

    # crm.Tools() builds its list through helper functions, so the names are the helpers'.
    code_tools=$(printf '%s\n' "$code_tools" | grep -v '^$' | sort -u)
    code_count=$(printf '%s\n' "$code_tools" | grep -c '.')

    if [ ! -f "$agent_readme" ]; then
        bad "agents/customer_service/README.md does not exist - the deployed agent is undocumented"
    else
        doc_tools=$(grep -ohE '^\| `(get|add|update|mark|save|list|current|search|scrape)[a-z0-9_]*`' \
            "$agent_readme" | tr -d '|` ' | sort -u)

        for t in $code_tools; do
            if ! printf '%s\n' "$doc_tools" | grep -qx "$t"; then
                bad "$t is registered by the backend and absent from $(basename "$agent_readme")"
            fi
        done
        for t in $doc_tools; do
            if ! printf '%s\n' "$code_tools" | grep -qx "$t"; then
                bad "$t is documented in $(basename "$agent_readme") and not registered by the backend"
            fi
        done
        note "$(printf '%s\n' "$code_tools" | grep -c '.') tools in the code, \
$(printf '%s\n' "$doc_tools" | grep -c '.') in the README"
    fi

    # 1b. Every tool description that reaches the model has to be non-empty, because an empty
    #     description is a tool the model cannot choose correctly and nothing else reports it.
    empty_desc=$(grep -rnE '^\s*Description:\s*""' "$GO_DIR/pkg" 2>/dev/null | cut -d: -f2 | tr '\n' ' ')
    if [ -n "$empty_desc" ]; then
        bad "tool definitions with an empty Description: line $empty_desc"
    else
        note "no empty tool descriptions"
    fi

    # 1c. The count of Name: literals versus the count the registry assembles. These are equal for the
    #     shape this codebase uses; a future registry that built names by concatenation would break
    #     the equality, and the message says which of the two numbers moved.
    literal_names=$(grep -rhoE '^\s*Name:\s*"[a-z0-9_]+"' "$GO_DIR/pkg" 2>/dev/null | wc -l | tr -d ' ')
    note "$literal_names Name: literals across pkg/, $code_count distinct tool names"
fi

# ---------------------------------------------------------------------------
# 2. Environment: documented, or set by the deployment
# ---------------------------------------------------------------------------
say "2 environment: every key the deployment sets appears in a table"

# The union of what compose sets and what the Go code reads with os.Getenv. The second half matters:
# a key the code reads and compose never sets is a default that silently runs in production, and that
# is worth documenting as loudly as one that is set.
set_keys=$(mktemp); got_keys=$(mktemp); doc_keys=$(mktemp)
trap 'rm -f "$set_keys" "$got_keys" "$doc_keys"' EXIT

grep -rhoE '^\s*-\s*[A-Z][A-Z0-9_]+=' "$AGENT_DIR"/*.yml "$AGENT_DIR"/*.yaml 2>/dev/null \
    | tr -d ' -=' | sed 's/=.*//' | sort -u > "$set_keys" || true
grep -rhoE '^\s{4,}[A-Z][A-Z0-9_]+:' "$AGENT_DIR"/*.yml "$AGENT_DIR"/*.yaml 2>/dev/null \
    | tr -d ' :' | sort -u >> "$set_keys" || true
# ENV lines in the Dockerfile are also the deployment setting a key, and the one that matters
# (SSL_CERT_FILE) appears nowhere else.
grep -hoE '^ENV\s+([A-Z][A-Z0-9_]+)' "$AGENT_DIR"/Dockerfile 2>/dev/null \
    | awk '{print $2}' | sort -u >> "$set_keys" || true
sort -u -o "$set_keys" "$set_keys"
grep -rhoE '\bos\.Getenv\("([A-Z][A-Z0-9_]+)"\)' "$GO_DIR/pkg" "$GO_DIR/cmd" 2>/dev/null \
    | sed -E 's/.*"([A-Z0-9_]+)".*/\1/' | sort -u >> "$got_keys" || true
# Constants named Env* hold the key names in this codebase, so they are Getenv's other half.
grep -rhoE '\bEnv[A-Za-z0-9]*\s*=\s*"([A-Z][A-Z0-9_]+)"' "$GO_DIR/pkg" "$GO_DIR/cmd" 2>/dev/null \
    | sed -E 's/.*"([A-Z0-9_]+)".*/\1/' | sort -u >> "$got_keys"
sort -u -o "$got_keys" "$got_keys"

for f in "$ROOT/README.md" "$ROOT/AGENTS.md" "$ROOT/QUICKSTART.md" "$ROOT/dev/README.md" \
         "$agent_readme" "$ROOT/docs/api.md" "$GO_DIR"/../../README.md; do
    [ -f "$f" ] && grep -ohE '`[A-Z][A-Z0-9_]{2,}`' "$f" | tr -d '`' >> "$doc_keys" || true
done
sort -u -o "$doc_keys" "$doc_keys"

while read -r k; do
    [ -n "$k" ] || continue
    # The Go runtime's own vocabulary is not this project's configuration.
    case "$k" in HOST|PORT|PATH|HOME|USER|TZ|LANG|GOPATH|GOFLAGS|CGO_ENABLED|GOPROXY|GOCACHE) continue ;; esac
    if ! grep -qx "$k" "$doc_keys"; then
        bad "$k is set by the deployment and documented nowhere"
    fi
done < "$set_keys"

while read -r k; do
    [ -n "$k" ] || continue
    case "$k" in HOST|PORT|PATH|HOME|USER|TZ|LANG|GOPATH|GOFLAGS|CGO_ENABLED|GOPROXY|GOCACHE) continue ;; esac
    if ! grep -qx "$k" "$doc_keys"; then
        bad "$k is read by the code and documented nowhere"
    fi
done < "$got_keys"

note "$(wc -l < "$doc_keys" | tr -d ' ') documented keys, \
$(wc -l < "$set_keys" | tr -d ' ') set by compose, $(wc -l < "$got_keys" | tr -d ' ') read by the code"

# ---------------------------------------------------------------------------
# 3. Views: what AGENTS.md advertises, asked of the database
# ---------------------------------------------------------------------------
say "3 views: every advertised vw_* exists"

# Two kinds of line are not claims that a view exists, and both were false positives in the first run
# of this section:
#
#   - a line that says the view is missing. AGENTS.md lists vw_entity_contact_details and
#     vw_communication_timeline with "not in the schema" on the same row, because T4's finding was that
#     a reader could not otherwise tell a live view from a superseded one. Demanding those names exist
#     would ask the docs to stop explaining themselves.
#   - anything inside a fenced code block. archive/blueprint/docs/views.md ends with a worked example of
#     writing your own view, CREATE OR REPLACE VIEW ... vw_my_custom_view; the name there is a
#     placeholder in a how-to, not a promise about the catalog.
#
# So the names are collected with fence state tracked and disclaimer lines dropped, which keeps the
# check to the prose that actually asserts something is there.
#
# The matcher is awk and not grep because fence state has to be carried across lines. Its regex leaves
# out \b on purpose: /usr/bin/awk on this host is mawk, which does not implement it, and a pattern
# mawk cannot match silently reports zero names - which this section's first run demonstrated by
# printing "9 views" for a file whose table has twenty. The count line below is what makes an empty
# scan visible instead of green.
declared=$(mktemp); trap 'rm -f "$set_keys" "$got_keys" "$doc_keys" "$declared" ' EXIT
for f in "$ROOT/AGENTS.md" "$ROOT/archive/blueprint/docs/views.md" "$ROOT/db/README.md"; do
    [ -f "$f" ] || continue
    awk '
        /^```/ { infence = !infence; next }
        infence { next }
        /not in the schema|is superseded|no such view|does not exist/ { next }
        {
            line = $0
            while (match(line, /vw_[a-z0-9_]+/)) {
                print substr(line, RSTART, RLENGTH)
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$f" >> "$declared"
done
# The Go source is a claim by construction: a query that names a view either parses or the binary does
# not start, so whatever it references has to exist for the deployment to work at all.
grep -rhoE '\bvw_[a-z0-9_]+' "$GO_DIR/pkg" 2>/dev/null >> "$declared" || true
sort -u -o "$declared" "$declared"
# Names that only ever appear in the places excluded above are still worth reporting, because a doc
# that says "not in the schema" about a view some migration added later is stale in the other
# direction. Counted, not failed.
caveated=$(mktemp)
for f in "$ROOT/AGENTS.md" "$ROOT/archive/blueprint/docs/views.md" "$ROOT/db/README.md"; do
    [ -f "$f" ] || continue
    grep -hoE '\bvw_[a-z0-9_]+' "$f" | sort -u >> "$caveated" || true
done
comm -13 <(sort -u "$declared") <(sort -u "$caveated") | grep -v '^$' > "$caveated.r" || true

if [ -n "${PSQL:-}" ] || command -v docker >/dev/null 2>&1 && docker inspect afpc-pg >/dev/null 2>&1; then
    exists=$(mktemp)
    if [ -n "${PSQL:-}" ]; then
        "$PSQL" -tAc "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public' AND c.relkind = 'v'" | sort -u > "$exists"
    else
        docker exec afpc-pg psql -U postgres -d "${AFPC_PG_DB:-agent_first_erp_crm}" -tAc \
            "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname='public' AND c.relkind='v'" | sort -u > "$exists"
    fi
    while read -r v; do
        [ -n "$v" ] || continue
        if ! grep -qx "$v" "$exists"; then
            bad "$v is advertised as existing and is not in the catalog (T4's shape: a doc row written from a superseded SQL file)"
        fi
    done < "$declared"
    note "$(wc -l < "$declared" | tr -d ' ') views claimed to exist, checked against the catalog"
    if [ -s "$caveated.r" ]; then
        note "also named, with their absence documented: $(tr '\n' ' ' < "$caveated.r" | sed 's/ $//')"
        # A view the docs disclaim that the catalog turns out to have is the stale-aside case above.
        while read -r v; do
            [ -n "$v" ] || continue
            grep -qx "$v" "$exists" && bad "$v is documented as not in the schema and the catalog says it is - the caveat is out of date"
        done < "$caveated.r"
    fi
    rm -f "$exists" "$caveated.r" "$caveated"
else
    skip "no database reachable (set PSQL or run where afpc-pg is up): $(wc -l < "$declared" | tr -d ' ') claimed view names not resolved"
fi

# ---------------------------------------------------------------------------
# 3b. Columns: the lists archive/blueprint/docs/views.md publishes
# ---------------------------------------------------------------------------
# Existence is all a grep can see, and T4's remaining half is not existence. The page's own header
# says its column lists were written against superseded SQL rather than the catalog, and 0017 measured
# one of them wrong in both directions - vw_agent_activity_summary listed bot_id, which the view never
# had, and omitted three columns it does. Either error is invisible to a check that only asks whether
# the view exists, and both end in an agent's query raising 42703 on a column the documentation named.
#
# So the lists are compared as sets. Order is not asserted, because a view's column order is whatever
# its SELECT says and a doc that lists alphabetically is not wrong.
say "3b columns: the published lists against pg_attribute"

page="$ROOT/archive/blueprint/docs/views.md"
if [ ! -f "$page" ]; then
    skip "no $page"
elif ! command -v docker >/dev/null 2>&1 && [ -z "${PSQL:-}" ]; then
    skip "no database reachable: the column lists are not compared"
else
    pairs=$(mktemp)
    awk '
        /^### (vw_[a-z0-9_]+)/ { view = $2; listed = 0; next }
        /^\*\*Columns:/ { if (view != "") listed = 1; next }
        /^### / && $0 !~ /^### vw_/ { view = ""; next }
        listed && /^- `[a-z_]+`/ {
            # match() rather than two subs: the line starts with the delimiter, so "strip everything
            # from the first backtick" strips the name as well and leaves an empty pair, which is the
            # bug this rule had - it printed one row per view with no column, and the comparison then
            # reported every real column of every view as undocumented.
            if (match($0, /`[a-z_]+`/)) {
                name = substr($0, RSTART + 1, RLENGTH - 2)
                if (name !~ /^vw_/) print view " " name
            }
        }
    ' "$page" | sort -u > "$pairs"

    real=$(mktemp)
    if [ -n "${PSQL:-}" ]; then
        "$PSQL" -tAc "SELECT c.relname||' '||a.attname FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname='public' AND c.relkind='v' AND a.attnum>0 AND NOT a.attisdropped" \
            | tr -s ' ' | sort -u > "$real"
    else
        docker exec afpc-pg psql -U postgres -d "${AFPC_PG_DB:-agent_first_erp_crm}" -tAc \
            "SELECT c.relname||' '||a.attname FROM pg_attribute a
              JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname='public' AND c.relkind='v' AND a.attnum>0 AND NOT a.attisdropped" \
            | tr -s ' ' | sort -u > "$real"
    fi

    # A view the page lists columns for but that does not exist has no rows in $real, and the
    # difference would be reported as "every column is wrong"; section 3 already names that case, so
    # the comparison is limited to views the catalog has.
    # named `listed`, and not `declared`: §3 above keeps its list of advertised views in a *tempfile*
    # called declared, and reusing that name here replaces the filename with view names, which the
    # EXIT trap then tries to rm -f and reports "File name too long" for the whole list.
    listed=$(cut -d' ' -f1 "$pairs" | sort -u | comm -12 - <(cut -d' ' -f1 "$real" | sort -u))
    for v in $listed; do
        want=$(grep "^$v " "$pairs" | cut -d' ' -f2 | sort -u)
        have=$(grep "^$v " "$real" | cut -d' ' -f2 | sort -u)
        extra=$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))
        miss=$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))
        [ -n "$extra" ] && bad "$v's list names $(echo $extra | tr '\n' ' ') which the view does not have (42703 for anyone who writes the query from the page)"
        [ -n "$miss" ] && bad "$v has $(echo $miss | tr '\n' ' ') that no list on the page mentions"
    done
    note "$(printf '%s\n' "$listed" | grep -c '.') view column lists compared, $(wc -l < "$pairs" | tr -d ' ') declared columns"
    rm -f "$pairs" "$real"
fi

# ---------------------------------------------------------------------------
# 4. Migrations: the ledger and the directory
# ---------------------------------------------------------------------------
say "4 migrations: db/MIGRATIONS.md and db/migrations agree"

ledger="$ROOT/db/MIGRATIONS.md"
if [ ! -f "$ledger" ]; then
    bad "db/MIGRATIONS.md is missing - nothing maps a check to the migration that closes it"
elif [ ! -d "$ROOT/db/migrations" ]; then
    bad "db/migrations is missing"
else
    for f in "$ROOT"/db/migrations/*.sql; do
        [ -e "$f" ] || continue
        v=$(basename "$f" .sql)
        grep -q "\`$v\`" "$ledger" || bad "$v exists as a file and is not a row in db/MIGRATIONS.md"
    done
    # Rows the ledger claims that have no file, excluding the renumbered plans, which are prose about
    # work not yet done and are identified in the ledger by their "(was planned as" marker.
    for v in $(grep -ohE '^\| `(0[0-9]{3}_[a-z0-9_]+)`' "$ledger" | tr -d '|` '); do
        [ -f "$ROOT/db/migrations/$v.sql" ] && continue
        grep -q "\`$v\`.*planned" "$ledger" && continue
        bad "db/MIGRATIONS.md lists $v and there is no such migration file"
    done
    note "$(ls "$ROOT"/db/migrations/*.sql 2>/dev/null | wc -l | tr -d ' ') files, \
$(grep -coE '^\| `(0[0-9]{3}_[a-z0-9_]+)`' "$ledger") ledger rows"
fi

# ---------------------------------------------------------------------------
# 5. Where objects live: the 3.1 claim, in the prose
# ---------------------------------------------------------------------------
say "5 schema qualification: no live document tells a caller to use the twin schema"

stale_file=$(mktemp)
trap 'rm -f "$set_keys" "$got_keys" "$doc_keys" "$declared" "$caveated" "$caveated.r" "$stale_file"' EXIT

# .py and .go files are not checked here: they are the code path, and code:tool_prefix in
# scripts/db/_common.sh watches that with a stricter rule. This section covers the prose, which is
# where the mistake survives a code sweep - a README that shows the qualified form as an example
# teaches it to the next caller, and no test of running code would ever notice.
#
# Two exemptions, both earned by false positives on the first full run:
#
#   - A mention counts as disclaimed if the surrounding lines say so. Prose wraps, and "the
#     `agent_first_erp_crm.` schema, which review 3.1 measured was never created by any migration" is
#     one sentence across two lines; demanding the caveat sit on the same physical line as the name
#     would be a formatting rule that rewards putting the explanation somewhere the check cannot see.
#     The window is two lines either side, which is a paragraph's worth of wrapping for a name that
#     appears mid-sentence.
#   - A file may declare itself a record with `docs-check: historical-record`. DATABASE_REVIEW.md and
#     FIX_SUMMARY.md consist of quotations of the state the authors found, and that is their whole
#     value; rewriting a finding record to satisfy a grep would make it assert something that never
#     happened, which is the failure this script hunts, not the cure.
marked=0
while IFS= read -r f; do
    if head -20 "$f" | grep -q 'docs-check: historical-record'; then
        grep -q 'agent_first_erp_crm\.' "$f" && marked=$((marked + 1))
        continue
    fi
    awk -v F="${f#$ROOT/}" '
        # Paragraphs, not a fixed line window: a mention is explained by the sentence it sits in, and
        # sentences wrap to whatever width the file keeps. Two lines either side was the first guess and
        # it missed a caveat three lines down in the same block, which is the kind of near miss that
        # teaches a reader to move the prose instead of the claim.
        { line[NR] = $0; para[NR] = np }
        { if ($0 ~ /^[ \t]*$/) np++ }          # a blank line ends the current paragraph
        END {
            lastp = np
            for (p = 0; p <= lastp; p++) {
                says = 0; mentions = 0
                for (i = 1; i <= NR; i++) {
                    if (para[i] != p) continue
                    if (line[i] ~ /agent_first_erp_crm\./) mentions++
                    if (line[i] ~ /the (old|twin|original|legacy|forked)|schema that|never created|did not create|no migration|absent|twin|superseded|legacy|renamed|no such|does not exist|fork|split|finding 3\.1|review 3\.|§3\.|database named|connection|dbname|host=|qualifier|symptom|root cause/)
                        says++
                }
                if (mentions == 0 || says > 0) continue
                for (i = 1; i <= NR; i++)
                    if (para[i] == p && line[i] ~ /agent_first_erp_crm\./)
                        printf "%s:%d:%s\n", F, i, line[i]
            }
        }
    ' "$f"
done < <(grep -rl --include='*.md' 'agent_first_erp_crm\.' "$ROOT" \
        --exclude-dir=.git --exclude-dir=node_modules 2>/dev/null | sort) > "$stale_file"

total=$(wc -l < "$stale_file" | tr -d ' ')
head -8 "$stale_file" | sed 's/^/       /'
if [ "$total" -gt 0 ]; then
    bad "documentation qualifies objects to the twin schema review 3.1 says no migration created \
($total lines listed by the rule above; the first 8 are shown)"
else
    note "no live documentation names the twin schema"
fi
[ "$marked" -gt 0 ] && note "$marked file(s) quote the twin schema under a historical-record marker"

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
if [ "$DOC_QUIET" -eq 1 ]; then
    [ "$fails" -eq 0 ] && echo 1 || echo 0
    exit $((fails > 0 ? 1 : 0))
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "  agent documentation matches the surface ($skips section(s) skipped)"
else
    echo "  $fails documentation drift(s): the prose describes an agent that is not the one in the code"
fi
exit "$fails"
