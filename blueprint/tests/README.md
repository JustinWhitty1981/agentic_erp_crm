# Agent First ERP CRM Test Suite

> # Read this before running anything here

**These are not tests in the sense the rest of this repository uses.** `grep -c 'def test_' *.py`
answers `0` for all five files: they are standalone scripts whose checks are `print` lines, and two of
them write to the database they connect to.

| File | On import |
|---|---|
| `test_create_functions.py` | connects to `POSTGRES_DB` (**default: `agent_first_erp_crm`, the live database**) and **commits** `DROP FUNCTION IF EXISTS add_customer(text x10)` - which matches nothing, the door takes 15 parameters, so the DROP is a no-op - and then `CREATE FUNCTION add_customer(text x10)` **succeeds**, installing a second head on the door whose body returns the constant `TRUE, 1, 1, 'Test'`. Measured in a scratch database: with both heads present, `SELECT * FROM add_customer('A','B','a@b.c','+15125550000')` fails *could not choose a best candidate function*, while a full-arity call still resolves to the real door. That is the finding 0016 was written to close, reopened by an import, and only the low-arity callers notice |
| `test_update_function.py` | the same against `update_customer` (12-parameter stub, 13-parameter real door) |
| `test_functions.py`, `verify_functions.py` | connect and `SELECT`; safe to read, not safe to trust as a check |
| `test_agent.py` | builds a LangChain agent against Ollama (`OLLAMA_MODEL`, default `ornith:35b`) - which is not what this project's agents use; they call vLLM (`VLLM_BASE_URL`). It will hang or refuse on this server |

Because `pytest` **imports** every module it collects, `pytest blueprint/tests/` performs the DDL above
before evaluating a single assertion, in whichever database the environment names. The commands
this page used to publish - `pytest blueprint/tests/ -v`, and building a test database out of
`scripts/database/*.sql`, which are the superseded pre-`0001` copies - are both withdrawn.

**To run one deliberately**, against a scratch database:

```bash
docker exec -it afpc-pg createdb -U postgres afpc_scratch
docker exec -i afpc-pg psql -U postgres -d afpc_scratch -f /dev/stdin < <(cat db/migrations/*.sql)   # the real schema
POSTGRES_DB=afpc_scratch POSTGRES_HOST=<pg-host> POSTGRES_USER=postgres python3 blueprint/tests/test_functions.py
```

**What actually checks this system** is the harness list in [`../../AGENTS.md`](../../AGENTS.md)
- `scripts/db/verify.sh`, `scripts/db/test-functions.sh` (which runs each probe against a *copy* with a
row-count residue check around it, the property these scripts lack), `go test ./...` in each deployed
agent, and `scripts/agents/tool_testplan.sh`. `PLAN.md` carries the fix for this directory: guard the
module bodies or delete the two files, since the function bodies they recreate predate 0016 and 0021 and
so assert nothing about what the doors do now.

---

**Purpose:** Comprehensive test suite for the Agent First ERP CRM blueprint.

---

## Overview

This test suite validates the core functionality of the Agent First ERP CRM system, including:

- Database function testing
- Agent behavior validation
- Customer tool functionality
- Integration tests

---

## Test Files

### test_functions.py

Tests SQL functions for customer management.

**Run:**
```bash
python test_functions.py
```

**Tests:**
No test functions: the file's "tests" are the `print` lines it executes on import, and
see the table above for the DDL it commits first. The functions it names
(`get_customer_by_id`, `delete_customer`) exist in neither the schema nor the code.

### test_create_functions.py

Tests creation of customer management functions.

**Run:**
```bash
python test_create_functions.py
```

**Tests:**
- `test_create_customer_function_exists` - Function exists
- `test_update_customer_function_exists` - Function exists
- `test_delete_customer_function_exists` - Function exists

### test_update_function.py

Tests updating existing customer records.

**Run:**
```bash
python test_update_function.py
```

**Tests:**
- `test_update_customer_name` - Update name field
- `test_update_customer_industry` - Update industry field
- `test_update_customer_multiple_fields` - Batch updates

### test_agent.py

Tests agent behavior and tool integration.

**Run:**
```bash
python test_agent.py
```

**Tests:**
- `test_agent_initialization` - Agent loads correctly
- `test_customer_lookup_tool` - Tool executes properly
- `test_communication_logging` - Logs interactions
- `test_error_handling` - Handles failures gracefully

### verify_functions.py

Verification script for all customer functions.

**Run:**
```bash
python verify_functions.py
```

**Verifies:**
- All customer functions are callable
- Functions return expected data types
- Functions handle edge cases

---

## Running Tests

### Prerequisites

1. PostgreSQL database with Agent First ERP CRM schema
2. Environment variables configured (there is no `.env.example` in `blueprint/`; the keys these scripts read are `POSTGRES_HOST/PORT/DB/USER/PASSWORD`, and `test_agent.py` adds `OLLAMA_MODEL`/`OLLAMA_BASE_URL`)
3. Python dependencies installed:
   ```bash
   pip install -r requirements.txt
   ```

### Run All Tests

```bash
# Using pytest
pytest blueprint/tests/ -v

# Run specific test file
pytest blueprint/tests/test_functions.py -v

# Run with coverage
pytest blueprint/tests/ --cov=blueprint
```

### Run Tests with Environment Variables

```bash
export POSTGRES_HOST=localhost
export POSTGRES_PORT=5432
export POSTGRES_DB=agent_first_erp_crm
export POSTGRES_USER=postgres
export POSTGRES_PASSWORD=your_password

python blueprint/tests/test_functions.py
```

---

## Test Database Setup

### Create Test Database

```sql
CREATE DATABASE agent_first_erp_crm_test;
```

### Apply Schema

```bash
../scripts/db/db up            # against a scratch database, not this one
# withdrawn: those .sql files are the superseded pre-0001 copies (see db/README.md).
# Apply db/migrations/ in filename order instead, and nothing else - that is what
# scripts/db/migrate.sh does, and what every probe in db/tests/ assumes.
# withdrawn: those .sql files are the superseded pre-0001 copies (see db/README.md).
# Apply db/migrations/ in filename order instead, and nothing else - that is what
# scripts/db/migrate.sh does, and what every probe in db/tests/ assumes.
# withdrawn: those .sql files are the superseded pre-0001 copies (see db/README.md).
# Apply db/migrations/ in filename order instead, and nothing else - that is what
# scripts/db/migrate.sh does, and what every probe in db/tests/ assumes.
# withdrawn: those .sql files are the superseded pre-0001 copies (see db/README.md).
# Apply db/migrations/ in filename order instead, and nothing else - that is what
# scripts/db/migrate.sh does, and what every probe in db/tests/ assumes.
```

### Load Sample Data

```bash
# withdrawn: those .sql files are the superseded pre-0001 copies (see db/README.md).
# Apply db/migrations/ in filename order instead, and nothing else - that is what
# scripts/db/migrate.sh does, and what every probe in db/tests/ assumes.
```

---

## Test Structure

```
blueprint/tests/
├── README.md              # This file
├── test_functions.py      # SQL function tests
├── test_create_functions.py  # Function creation tests
├── test_update_function.py   # Update operation tests
├── test_agent.py          # Agent behavior tests
└── verify_functions.py    # Function verification
```

---

## Writing New Tests

### Test Pattern

```python
import unittest
import psycopg2
from dotenv import load_dotenv
import os

load_dotenv()

class TestCustomerFunctions(unittest.TestCase):
    
    def setUp(self):
        """Set up test database connection."""
        self.conn = psycopg2.connect(
            host=os.getenv("POSTGRES_HOST", "localhost"),
            database=os.getenv("POSTGRES_DB", "agent_first_erp_crm_test"),
            user=os.getenv("POSTGRES_USER", "postgres"),
            password=os.getenv("POSTGRES_PASSWORD", "")
        )
    
    def tearDown(self):
        """Clean up after test."""
        self.conn.close()
    
    def test_example(self):
        """Example test case."""
        cursor = self.conn.cursor()
        cursor.execute("SELECT * FROM get_customer_by_id(1)")
        result = cursor.fetchone()
        self.assertIsNotNone(result)
        cursor.close()
```

### Best Practices

1. **Use test database:** Never test against production
2. **Clean up after tests:** Rollback changes in tearDown
3. **Test edge cases:** Null values, empty strings, special characters
4. **Test error handling:** Verify proper error messages
5. **Use meaningful names:** Test method names should describe what's being tested

---

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_DB: agent_first_erp_crm_test
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: test
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    steps:
      - uses: actions/checkout@v2
      - name: Set up Python
        uses: setup-python@v2
        with:
          python-version: '3.11'
      - name: Install dependencies
        run: |
          pip install -r blueprint/requirements.txt
      - name: Run tests
        env:
          POSTGRES_HOST: localhost
          POSTGRES_PORT: 5432
          POSTGRES_DB: agent_first_erp_crm_test
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: test
        run: |
          pytest blueprint/tests/ -v
```

---

## Troubleshooting

### Connection Errors

```
psycopg2.OperationalError: connection refused
```

**Solution:** Ensure PostgreSQL is running and environment variables are set correctly.

### Function Not Found

```
psycopg2.errors.UndefinedFunction: function get_customer_by_id(integer) does not exist
```

**Solution:** none - and the script this page used to name is the wrong answer twice over.
`get_customer_by_id` is not missing, it never existed (measured: 0 rows in `pg_proc`), and
`scripts/database/09_customer_functions.sql` would not create it either: it defines
`add_customer`/`update_customer`/`get_followup_customers` qualified into `agent_first_erp_crm`, the
schema no migration creates, and running it recreates pre-0016 function bodies in a database that has
already moved past them. The read the old example wanted is a view:

```sql
SELECT id, name, email, phone, status FROM vw_customers WHERE id = 123;
```

### Test Database Missing

```
psycopg2.errors.InvalidCatalogName: database agent_first_erp_crm_test does not exist
```

**Solution:** Create the test database:
```bash
createdb agent_first_erp_crm_test
```

---

## Coverage Report

```bash
pytest blueprint/tests/ --cov=blueprint --cov-report=html
```

Open `htmlcov/index.html` in a browser to view coverage.

---

*Generated for Agent First ERP CRM - Test suite documentation*