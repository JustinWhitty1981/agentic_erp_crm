# archive/ — frozen lineage

Nothing in this directory runs, builds, deploys, or grows. Files land here **complete**, with a banner
on their README saying what superseded them and why — see
[`blueprint/README.md`](blueprint/README.md) and
[ADR-006](../ARCHITECTURE_DECISION_RECORDS/ADR-006_go_runtime_over_python_reference.md).

Why archive instead of delete: this code is the ancestry of both deployed agents, several `code:*`
harness greps still read `archive/blueprint/**/*.py` as guards, and `docs/history/` pages cite its
paths. Deleting it would break checks that guard live code and would make the history pages
unresolvable — so it moves, stays byte-frozen, and stops being an on-ramp.

Rules:

1. **No edits**, except to documentation inside the archived tree when a link it contains stops
   resolving (a path that 404s is a defect wherever it lives).
2. **No new children** without a decision record saying what is being retired and what replaced it.
3. The harnesses that grep this tree point at these paths on purpose: they are canaries. If someone
   revives archived code into the live surface, the greps find it — which is the point of keeping the
   files readable rather than deleting them.
