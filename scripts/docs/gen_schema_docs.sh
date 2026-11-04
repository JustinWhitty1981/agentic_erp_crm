#!/usr/bin/env bash
# gen_schema_docs.sh - regenerate docs/database/{tables,views,indexes}.md from the running catalog.
#
# Why a script and not a recipe: the Makefile's version of this ran
# `scripts/db/db shell -c "\dt+" > docs/database/tables.md`, and two things were wrong with it. The
# `shell` subcommand dropped its arguments, so the psql invocation never happened and the target
# "wrote" an empty file while reporting success - the exact shape of failure a generator should not be
# able to produce. And `\dt+`'s aligned output pads the Description column to whatever the longest
# comment is, which for this schema was a 400-character paragraph per row: technically a table,
# unreadably a document.
#
# So the queries are SQL, one column per fact, and the header is written by this file so that a reader
# can tell generated from hand-maintained without asking. The catalog is the only source: a list of
# tables copied into a .md is a list that will describe a database that no longer exists, which is
# T4's whole subject.
#
# What the three files deliberately do not answer, and where the answer is:
#   - which indexes are redundant      -> vw_index_redundancy
#   - which tables RLS actually binds  -> vw_rls_status
#   - which tables leave a row trail   -> vw_audit_coverage
#   - which timestamps can be trusted  -> vw_timestamp_status
# Those are views *of the catalog*, written in SQL for exactly this reason, and this page is the right
# place to say so, because a generated list with no pointer is a list people stop reading.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DB="${DB:-$ROOT/scripts/db/db}"
OUT="${1:-$ROOT/docs/database}"
TODAY="$(date -u +%Y-%m-%d)"

[ -d "$OUT" ] || { echo "no such directory: $OUT"; exit 1; }
[ -x "$DB" ] || { echo "no db command at $DB"; exit 1; }

# query <sql> -> rows, tab-free and trimmed, or nothing at all when the catalog is unreachable.
query() {
    "$DB" shell -tA -F '|' -c "$1" 2>/dev/null
}

written=0

gen() {
    local file="$1" noun="$2" note="$3" sql="$4" header="$5"
    local rows
    rows="$(query "$sql")"
    if [ -z "$rows" ]; then
        echo "  SKIP $file - the catalog answered nothing (is afpc-pg running?)"
        return 1
    fi
    {
        printf '# Database %s - generated\n\n' "$noun"
        printf 'Regenerated from the live catalog by `scripts/docs/gen_schema_docs.sh` (the `make\n'
        printf 'docs-schema` target) on %s. **Do not edit**: the next run replaces this file. Prose\n' "$TODAY"
        printf 'about %s belongs in `db/README.md`; the checks over them live in\n' "$noun"
        printf '`scripts/db/verify.sh`.\n\n'
        printf '%s\n\n' "$note"
        printf '```\n%s\n%s\n```\n' "$header" "$rows"
    } > "$OUT/$file"
    printf '  %s  %s rows\n' "$file" "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
    written=$((written + 1))
}

# Tables, with the facts a caller needs beside the name rather than a row count from a stale ANALYZE:
# relkind distinguishes a partitioned parent (p) from a plain table (r), and `relrowsecurity` is the
# answer to "does RLS apply here" as the catalog sees it, not as the migration that added the table
# intended it to.
gen tables.md "tables" \
    'What this cannot show is whether the policies are FORCED or work, or which tables leave a trail:
`vw_rls_status` and `vw_audit_coverage` answer those, in SQL, from the same catalog.' \
    "SELECT c.relname,
            CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned' ELSE c.relkind::text END,
            (SELECT count(*) FROM pg_policy pol WHERE pol.polrelid = c.oid),
            CASE WHEN c.relrowsecurity THEN 'on' ELSE 'off' END,
            coalesce(obj_description(c.oid), '')
       FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind IN ('r','p')
      ORDER BY 1" \
    'name | kind | policies | rls | comment'

# Views, with the one property that changes what a caller sees through them: security_invoker means the
# querying role's own row security applies, and definer means the view owner's does. 0009's ordering
# rule - grants after creates, because CREATE OR REPLACE VIEW drops the grants - is the reason the
# column is worth printing rather than assuming.
#
# The flag is a reloption in this server's version, not a pg_class column: `relsecurityinvoker` does not
# exist, and a generator written as if it did would error rather than print 'definer' for all
# seventeen, which is the better of the two failures and the only reason this was caught here.
gen views.md "views" \
    'The extension views pg_stat_statements installs are in here as well, because the catalog does not
distinguish them; the vw_ ones belong to the project. scripts/docs/check_agent_docs.sh is the check that
the names the prose promises match this list, in both directions: advertised-and-absent, and
disclaimed-and-present.' \
    "SELECT c.relname,
            CASE WHEN 'security_invoker=true' = ANY (coalesce(c.reloptions, '{}'::text[]))
                 THEN 'invoker' ELSE 'definer' END,
            coalesce(obj_description(c.oid), '')
       FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind = 'v'
      ORDER BY 1" \
    'name | invoker-or-definer | comment'

# Indexes, one definition per line. The point of printing indexdef rather than a name is that the
# definition is what shows a leading column list: 0006's rule is that every index on a tenant-coded
# table starts with tenant_id, and that is readable here without another join.
gen indexes.md "indexes" \
    'Redundancy is not visible in a list, and this one does not pretend it is: `vw_index_redundancy`
names the pairs that are identical or a leading prefix of another.' \
    "SELECT tablename || ' :: ' || indexdef FROM pg_indexes
      WHERE schemaname = 'public' ORDER BY tablename, indexname" \
    'table :: definition'

echo "  $written file(s) regenerated in ${OUT#"$ROOT"/}"
[ "$written" -gt 0 ] || exit 1
