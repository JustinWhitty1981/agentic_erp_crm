# Agent First ERP CRM Test Suite

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
- `test_get_customer_by_id` - Customer lookup by ID
- `test_search_customers_by_name` - Name-based search
- `test_create_customer` - Customer creation
- `test_update_customer` - Customer updates
- `test_delete_customer` - Soft delete

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
2. Environment variables configured (see `.env.example`)
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
psql -h localhost -U postgres -d agent_first_erp_crm_test -f scripts/database/agent_first_erp_crm_schema.sql
psql -h localhost -U postgres -d agent_first_erp_crm_test -f scripts/database/08_create_views.sql
psql -h localhost -U postgres -d agent_first_erp_crm_test -f scripts/database/09_customer_functions.sql
psql -h localhost -U postgres -d agent_first_erp_crm_test -f scripts/database/10_audit_log.sql
psql -h localhost -U postgres -d agent_first_erp_crm_test -f scripts/database/11_interaction_logging.sql
```

### Load Sample Data

```bash
psql -h localhost -U postgres -d agent_first_erp_crm_test -f scripts/database/setup_sample_data.sql
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

**Solution:** Run the customer functions script:
```bash
psql -f scripts/database/09_customer_functions.sql
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