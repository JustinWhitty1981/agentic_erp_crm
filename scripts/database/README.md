# Database Setup Scripts - **SUPERSEDED. Do not run anything in this directory.**

> Every file here is a pre-`0001` copy of SQL that has since been ported, corrected and superseded;
> `db/README.md` lists them file by file against the migration that replaced each one. The schema lives
> in `db/migrations/` and is applied by:
>
> ```bash
> scripts/db/db up          # container, roles, migrations, verify
> scripts/db/db seed        # db/seeds/*.sql, idempotent
> scripts/db/db verify      # the structural assertions
> ```
>
> **Two commands this page used to recommend will damage a working database, and the warning is the
> reason this banner is longer than the page:**
>
> | The command | What actually happens |
> |---|---|
> | `python3 scripts/database/setup_customer_functions.py` | Parses no arguments - there is no `--verify`, no `--help`, nothing it accepts - and its module-level SQL runs `DROP FUNCTION IF EXISTS add_customer(...)`, `update_customer(...)` and `get_followup_customers(INTEGER)` in `public`, then recreates the pre-0001 bodies. That removes the doors both deployed agents write through (0016, 0021, 0022's rewrite included), so `add_customer` stops existing as the function `db/tests/4_4` and `4_7` assert, the agent's tools start erroring, and `verify.sh` fails. **Run against a copy, never the live database** - and there is no reason to run it against a copy either, because `db/migrations/` is the definition |
> | `python3 -m pytest scripts/tests/` | Same story from the other direction: see `scripts/tests/README.md`. Those modules do DDL at import time |
> | `python3 scripts/database/apply_functions.py` | Cannot work: line 23 opens `09_add_update_customer_functions.sql` **in this directory**, and the file here is named `09_customer_functions.sql`. FileNotFoundError before it touches a database |
> | `./scripts/database/apply_customer_functions.sh` | Cannot work either: it bind-mounts `$(pwd)/09_add_update_customer_functions.sql` into a container, which does not exist here |
> | `psql -f scripts/database/agent_first_erp_crm_schema.sql` | This directory has no such file (the copy is `docs/database/agent_first_erp_crm_schema.sql`, itself superseded) |
>
> The `09_customer_functions.sql` in this directory also creates its functions in `agent_first_erp_crm`,
> the schema `DATABASE_REVIEW.md` 3.1 measured that no migration creates, so even the SQL that "ran" here
> wrote into a schema the rest of the system cannot see through the `vw_*` views. And
> `11_interaction_logging.sql`'s full-text GIN index on `human_input` was not carried by the canonical
> port: the live `agent_interactions` has no such index, which is why a keyword search over interaction
> text is a sequential scan and why no tool offers one.
>
> What is still true about these files: they are the ancestry. `0001` was ported from them, the review's
> findings quote them, and `docs/database/DATABASE_REVIEW.md` cites their line numbers as evidence. That
> is why they are kept rather than deleted, and why the fix for a defect they describe is a numbered
> migration and never an edit here.

---

This directory contains all SQL migration scripts and Python helpers for setting up and managing the Agent First ERP CRM database.

## 📂 Directory Structure

```
scripts/database/
├── agent_first_erp_crm_schema.sql       # Complete database schema definition
├── setup_sample_data.sql        # Sample data for testing
├── 08_create_views.sql          # Database views for common queries
├── 09_customer_functions.sql    # Customer management SQL functions
├── 10_audit_log.sql             # Audit logging functions and triggers
├── 11_interaction_logging.sql   # Agent interaction tracking table & indexes
├── apply_functions.py           # Python script to deploy SQL functions
├── apply_customer_functions.sh  # Shell script alternative for deployment
└── setup_customer_functions.py  # Helper for customer function setup
```

## 🚀 Quick Start

### Option 1: Automated Deployment (Recommended)

Run the Python deployment script:
```bash
cd /home/justin/.openclaw/workspace/github/agent_first_erp_crm
python3 scripts/database/apply_functions.py
```

This will:
1. Connect to the PostgreSQL database
2. Execute all SQL function definitions
3. Create necessary views and triggers
4. Report success/failure for each step

### Option 2: Manual SQL Execution

If you prefer manual control:
```bash
# Set environment variables first
export POSTGRES_HOST=${POSTGRES_HOST:-localhost}
export POSTGRES_PORT=${POSTGRES_PORT:-5432}
export POSTGRES_DB=${POSTGRES_DB:-agent_first_erp_crm}
export POSTGRES_USER=${POSTGRES_USER:-postgres}
export POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

# Connect to database
psql -h "${POSTGRES_HOST}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"

# Execute scripts in order
\i /home/justin/.openclaw/workspace/github/agent_first_erp_crm/scripts/database/agent_first_erp_crm_schema.sql
\i /home/justin/.openclaw/workspace/github/agent_first_erp_crm/scripts/database/08_create_views.sql
\i /home/justin/.openclaw/workspace/github/agent_first_erp_crm/scripts/database/09_customer_functions.sql
\i /home/justin/.openclaw/workspace/github/agent_first_erp_crm/scripts/database/10_audit_log.sql
\i /home/justin/.openclaw/workspace/github/agent_first_erp_crm/scripts/database/11_interaction_logging.sql  # NEW: Interaction tracking
\i /home/justin/.openclaw/workspace/github/agent_first_erp_crm/scripts/database/setup_sample_data.sql
```

### Option 3: Shell Script

```bash
./scripts/database/apply_customer_functions.sh
```

## 📋 Script Descriptions

### Core Schema
- **`agent_first_erp_crm_schema.sql`**: Complete database schema including:
  - Customer tables (customers, customer_contacts, customer_addresses)
  - Conversation tracking tables
  - Audit log tables
  - Vector search support (PGVector)

### Views
- **`08_create_views.sql`**: Creates optimized views for:
  - Customer summaries with contact info
  - Conversation history with metadata
  - Recent activity dashboards

### Functions
- **`09_customer_functions.sql`**: SQL functions for:
  - `add_customer()`: Insert new customers with validation
  - `update_customer()`: Modify existing customer data
  - `search_customers()`: Fuzzy search with PGVector
  - `get_customer_history()`: Retrieve full customer timeline

### Audit System
- **`10_audit_log.sql`**: 
  - Automatic audit triggers on all customer tables
  - `audit_log` table for change tracking
  - `get_audit_history()` function for compliance

### Interaction Logging
- **`11_interaction_logging.sql`**: 
  - `agent_interactions` table for full conversation tracking
  - Captures agent thoughts, actions, and observations
  - Links to Telegram chat/user IDs for traceability
  - Full-text search on human input
  - Performance metrics and error tracking

### Sample Data
- **`setup_sample_data.sql`**: 
  - 10 sample customers with realistic data
  - Sample conversations and interactions
  - Test data for development

## 🔧 Configuration

### Environment Variables
Set these before running scripts:
```bash
export POSTGRES_HOST=${POSTGRES_HOST:-localhost}
export POSTGRES_PORT=${POSTGRES_PORT:-5432}
export POSTGRES_DB=${POSTGRES_DB:-agent_first_erp_crm}
export POSTGRES_USER=${POSTGRES_USER:-postgres}
export POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
```

Or use `.env` file in the blueprint directory.

## ✅ Verification

After setup, verify the installation:
```bash
# Check if functions exist
psql -h "${POSTGRES_HOST:-localhost}" -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-agent_first_erp_crm}" -c "\df add_customer"

# Check views
psql -h "${POSTGRES_HOST:-localhost}" -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-agent_first_erp_crm}" -c "\dv customer_summary"

# Run test queries
python3 scripts/database/setup_customer_functions.py --verify
```

## 🐛 Troubleshooting

### Connection Errors
- Verify PostgreSQL is running: `systemctl status postgresql`
- Check credentials in environment variables
- Ensure network connectivity to database host

### Function Already Exists
```sql
-- Drop and recreate if needed
DROP FUNCTION IF EXISTS add_customer CASCADE;
-- Then re-run the apply script
```

### Permission Issues
```bash
# Grant necessary permissions
psql -h "${POSTGRES_HOST:-localhost}" -U "${POSTGRES_USER:-postgres}" -c "GRANT ALL ON DATABASE ${POSTGRES_DB:-agent_first_erp_crm} TO ${POSTGRES_USER:-postgres};"
```

## 📚 Related Documentation

- [Database Mental Model](../../docs/database/agent_first_erp_crm_mental_model.md)
- [Schema Reference](../../docs/database/agent_schema_reference.md)
- [Blueprint Documentation](../../archive/blueprint/README.md)

## 🤖 Agent Usage

When working with this directory:
1. **Always run scripts in order** - Schema → Views → Functions → Audit → Sample Data
2. **Test after each step** - Verify changes before proceeding
3. **Use transactions** - Wrap multiple scripts in a transaction for rollback capability
4. **Backup first** - Always backup production databases before schema changes

Example safe deployment:
```bash
psql -h "${POSTGRES_HOST:-localhost}" -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-agent_first_erp_crm}" << 'EOF'
BEGIN;
\i agent_first_erp_crm_schema.sql
\i 08_create_views.sql
\i 09_customer_functions.sql
\i 10_audit_log.sql
COMMIT;
EOF
```
