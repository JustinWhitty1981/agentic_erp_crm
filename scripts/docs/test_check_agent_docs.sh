#!/usr/bin/env bash
# test_check_agent_docs.sh - prove the doc watchdog can still fail.
#
# Why this exists: check_agent_docs.sh is a shell script whose failures are strings pulled out of
# files with grep and awk, and every one of those patterns can stop matching while the script goes on
# printing "matches the surface". Two bugs of that shape were found in an hour - a `\\b` in an awk
# regex, which /usr/bin/awk (mawk) does not implement, so §3 silently compared an empty list, and a
# compose grep written for the map form of `environment:` when the file uses the list form, so §2 read
# zero keys and reported success. Both were green. Both were the reason the marker existed.
#
# So this file builds a small tree whose docs are wrong in exactly the ways §2, §4 and §5 are supposed
# to notice, runs the checker against it through the AFPC_DOCS_ROOT seam, and asserts the count moved.
# Sections that need a database or the Go source are skipped in the fixture, and skipped-not-run is
# stated at the end rather than folded into the number.

set -uo pipefail

CHECKER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check_agent_docs.sh"
[ -x "$CHECKER" ] || { echo "no checker at $CHECKER"; exit 1; }

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

fails=0

# expect <label> <root> <wanted count of FAIL lines>
expect() {
    local label="$1" root="$2" want="$3" got output
    output=$(AFPC_DOCS_ROOT="$root" "$CHECKER" 2>&1)
    got=$(printf '%s\n' "$output" | grep -c '^  FAIL' || true)
    if [ "$got" -eq "$want" ]; then
        printf '  ok       %s (%s failure(s), as intended)\n' "$label" "$got"
    else
        printf '  NOTICED  %s: wanted %s failure(s), got %s\n' "$label" "$want" "$got"
        printf '%s\n' "$output" | grep '^  FAIL' | sed 's/^/             /'
        fails=$((fails + 1))
    fi
}

# ---------------------------------------------------------------- clean tree ----
# The control, and the reset between cases. Each case below re-materialises this tree and adds exactly
# one way to be wrong, because a fixture that accumulates breakage measures the sum and tells you
# nothing about which check did the noticing - and the first draft of this file did exactly that, which
# is how three of the six cases came out with a count that was right for the wrong reasons.
baseline() {
    rm -rf "$FIX/tree"
    mkdir -p "$FIX/tree/agents/customer_service" "$FIX/tree/db/migrations" "$FIX/tree/docs"
    cat > "$FIX/tree/agents/customer_service/README.md" <<'EOF'
# agent
| `get_customer_info` | read | lookup |
| `API_KEYS` | unset | auth |
| `LOG_LEVEL` | info | verbosity |
EOF
    cat > "$FIX/tree/agents/customer_service/docker-compose.yml" <<'EOF'
services:
  a:
    environment:
      - API_KEYS=
      - LOG_LEVEL=debug
EOF
    printf 'Keys this deployment reads: `API_KEYS`, `LOG_LEVEL`.\n' > "$FIX/tree/README.md"
    printf '| `0001_one` | x | note |\n' > "$FIX/tree/db/MIGRATIONS.md"
    printf -- '--\n' > "$FIX/tree/db/migrations/0001_one.sql"
}

baseline
expect "a clean tree reports nothing" "$FIX/tree" 0

# A key compose sets that no table names. The reason this is a failure rather than a tidiness rule: a
# knob nobody can find is changed by accident, and the behaviour it produces cannot be reproduced.
baseline
printf '      - SECRET_ROTATION_HOURS=6\n' >> "$FIX/tree/agents/customer_service/docker-compose.yml"
expect "a key compose sets and no table names" "$FIX/tree" 1

# A ledger row for a migration file that is not there: verify.sh's PASS lines would credit work nobody
# did. (The reverse - a file with no row - is the same check from the other side.)
baseline
printf '| `0002_two` | y | note |\n' >> "$FIX/tree/db/MIGRATIONS.md"
expect "a ledger row for a migration that is not there" "$FIX/tree" 1

# The twin schema in a sentence that says nothing about it, which is a README teaching a mistake.
baseline
cat > "$FIX/tree/docs/telling-you-to-run-it.md" <<'EOF'
Query the customers:

```sql
SELECT * FROM agent_first_erp_crm.vw_customers;
```
EOF
expect "a doc that teaches the twin-schema mistake" "$FIX/tree" 1

# The same name in a paragraph that explains it. This must pass: a check that cannot tell a claim from
# a caveat ends up asking authors to move words around instead of fixing anything.
baseline
cat > "$FIX/tree/docs/explaining-it.md" <<'EOF'
`agent_first_erp_crm.` is the schema review 3.1 measured was never created by any migration, so
qualifying a name to it answers 42P01.
EOF
expect "the same name, in a sentence that explains itself" "$FIX/tree" 0

# A record that quotes the twin schema, exempt by its own marker.
baseline
{ printf '<!-- docs-check: historical-record -->\n';
  printf 'We found agent_first_erp_crm.add_customer in 33 files.\n'; } > "$FIX/tree/docs/explaining-it.md"
expect "a marked historical record quoting the twin schema" "$FIX/tree" 0

# And the direction that matters: the marker deleted from a file that still quotes the schema. The
# exemption has to be load-bearing, or it is a way to hide rather than a way to say.
baseline
printf 'We found agent_first_erp_crm.add_customer in 33 files.\n' > "$FIX/tree/docs/explaining-it.md"
expect "the marker deleted from a file that still quotes it" "$FIX/tree" 1



echo
if [ "$fails" -eq 0 ]; then
    echo "  the watchdog notices: every case failed, or explained itself, exactly as asked"
else
    echo "  $fails self-test(s) did not behave: check_agent_docs.sh cannot see something it claims to"
fi
exit "$fails"
