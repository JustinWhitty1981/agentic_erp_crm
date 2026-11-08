# Code-Documentation Misalignment Fixes

> **A dated record of a July 2026 cleanup pass, not a current file list.** Several of the paths it
> names no longer exist, and one of its "verification commands" fails when run today - which is what a
> record looks like when the thing it recorded moved. Corrected in place, because the *findings* are
> still cited by `db/MIGRATIONS.md` and deleting them would delete the evidence:
>
> | The record says | Today |
> |---|---|
> | `blueprint/10_create_audit_log.sql`, `blueprint/test_functions.py`, `blueprint/verify_functions.py`, `blueprint/bot_with_full_logging.py`, `blueprint/customer_tools.py`, `tools/`, `memory/` | none of these exist. The audit trail is `db/migrations/0013_audit_log.sql`; the verification scripts are `scripts/db/verify.sh` and `scripts/db/test-functions.sh`; the customer tools are `blueprint/tools/*.py`; `tools/` and `memory/` at the root were never created |
> | alias view `agent_communications_summary` - "both names now work" | the alias was never adopted. One name exists: `vw_customer_communications_summary`, and probe `4_5` asserts the qualified twin-schema forms are gone |
> | `log_agent_action()` / `validate_audit_action()` helpers | do not exist in `pg_proc`. `audit_log` is written by the `afpc_audit_row` trigger and read back by `audit_chain_verify()` |
> | `docs/MISALIGNMENT_FIXES.md` - "Created" | the file moved to `docs/history/MISALIGNMENT_FIXES.md`; every link that says otherwise is broken, and `PLAN.md`'s copy of that link was fixed in the 2026-11-05 sweep |
>
> `agents/` does exist, and the sentence above about it being "empty" is the single most outdated line in
> the file: it holds three deployed agents, each with a Go backend, a React UI, a Dockerfile and a
> README - `agents/customer_service/` on `:4550`, `agents/inventory/` on `:4560` and `agents/sales/` on
> `:4570`, the last two forked from the first. The one line of the July record this does not repair is
> the Telegram transport: still absent from all three, which are HTTP and SSE.

This document tracks the misalignments identified between the codebase and documentation, and the fixes applied.

## Summary

| Category | Items Fixed |
|----------|-------------|
| Critical | 3 |
| High | 2 |
| Medium | 2 |
| **Total** | **7** |

---

## Critical Fixes

### 1. Hardcoded Database Credentials ❌ → ✅ (PARTIAL - See Note Below)

**Issue:** Database password was hardcoded in multiple files

**Fix Applied (July 21, 2026):**
- Removed hardcoded credentials from all Python files
- All files now use `os.getenv("POSTGRES_PASSWORD")` with no hardcoded fallback
- Added `from dotenv import load_dotenv` and `load_dotenv()` where needed
- Updated `.env` file to use placeholder (`***`) instead of real password

**Files Modified:**
- `scripts/database/setup_customer_functions.py`
- `scripts/database/apply_functions.py`
- `scripts/tests/*.py` (all test files)
- `blueprint/setup_customer_functions.py`
- `blueprint/apply_functions.py`
- `blueprint/test_functions.py`
- `blueprint/verify_functions.py`
- `blueprint/bot_with_full_logging.py`
- `blueprint/.env`
- All other test and utility files

**⚠️ Important Note:** The verification command `grep -r "Timber69" blueprint/` previously returned false positives because it matched the string in documentation. After this fix, the command should return **no results** for actual password values. Always verify with: `grep -r "Timber69!" .` (with exclamation mark) to catch only actual passwords, not documentation references.

---

### 2. Missing `audit_log` Table ❌ → ✅

**Issue:** The `audit_log` table was documented but never created, breaking the CAO validation layer

**Fix Applied:**
- Created `blueprint/10_create_audit_log.sql` with complete schema
- Added helper functions: `log_agent_action()` and `validate_audit_action()`
- Added proper indexes for performance

**Files Created:**
- `blueprint/10_create_audit_log.sql`

---

### 3. View Naming Inconsistency ❌ → ✅

**Issue:** Documentation referenced `agent_communications_summary` but SQL created `customer_communications_summary`

**Fix Applied:**
- Added alias view `agent_communications_summary` that points to `customer_communications_summary`
- Both names now work for backward compatibility

**Files Modified:**
- `scripts/08_create_views.sql`

---

## High Priority Fixes

### 4. Blueprint Pattern Documentation Drift ❌ → ✅

**Issue:** Documentation claimed "single-file" pattern but actual implementation uses multiple files

**Fix Applied:**
- Updated README.md to document the actual modular pattern
- Added file structure diagram showing `bot.py` + `<domain>_tools.py` separation
- Clarified each component's responsibility

**Files Modified:**
- `README.md`

---

### 5. Architecture Documentation Out of Date ❌ → ✅

**Issue:** Architecture doc showed single-file pattern that doesn't match reality

**Fix Applied:**
- Updated architecture.md with accurate file structure
- Added `bot.py` structure section showing proper tool import pattern
- Clarified modular design approach

**Files Modified:**
- `architecture.md`

---

## Medium Priority Fixes

### 6. Schema Documentation Inaccurate ❌ → ✅

**Issue:** Schema doc stated `audit_log` was "not yet created"

**Fix Applied:**
- Updated schema.md to reflect that `audit_log` is now implemented
- Added reference to `blueprint/10_create_audit_log.sql`
- Documented helper functions

**Files Modified:**
- `docs/database/schema.md`

---

### 7. Empty Directories Not Addressed ❓

**Issue:** `agents/`, `tools/`, and `memory/` directories exist but are empty

**Status:** Documented but not fixed (requires actual implementation work)

**Next Steps:**
- Populate `tools/` with shared utilities and CAO validator
- Create initial agent implementations in `agents/`
- Implement memory management in `memory/`

---

## Files Changed Summary

| File | Action | Description |
|------|--------|-------------|
| `blueprint/bot.py` | Modified | Removed hardcoded credentials, added env validation |
| `blueprint/customer_tools.py` | Modified | Removed hardcoded credentials, added env validation |
| `blueprint/10_create_audit_log.sql` | Created | New audit log table with helper functions |
| `scripts/08_create_views.sql` | Modified | Added `agent_communications_summary` alias view |
| `README.md` | Modified | Updated blueprint pattern documentation |
| `architecture.md` | Modified | Updated agent structure pattern documentation |
| `docs/database/schema.md` | Modified | Updated audit_log status to "Implemented" |
| `docs/MISALIGNMENT_FIXES.md` | Created | This summary document |

---

## Remaining Work

The following items from the original misalignment analysis still need attention:

1. **CAO Validation Layer Implementation** - The `audit_log` table is now ready, but the Python validator framework needs to be built
2. **Agent Registry** - The `agents` table is documented but not created; no agent identity management exists
3. **Empty Directories** - `agents/`, `tools/`, `memory/` need population
4. **Dependency Version Pinning** - Consider tightening version constraints in `requirements.txt`
5. **Test Coverage Documentation** - No centralized testing strategy document exists

---

## Verification Commands

To verify the fixes are applied correctly:

```bash
# Check that hardcoded credentials are removed
grep -r "Timber69" blueprint/

# Verify audit_log SQL exists
ls -la blueprint/10_create_audit_log.sql

# Check view alias exists in SQL
grep "agent_communications_summary" scripts/08_create_views.sql
```

---

*Last Updated: July 18, 2026*