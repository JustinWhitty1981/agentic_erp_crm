# Test Suite

This directory contains the comprehensive test suite for the Agent Swarm system. These tests validate the database functions, agent behavior, and customer management tools.

## 📂 Test Files

```
scripts/tests/
├── test_agent.py              # Tests the main bot agent
├── test_create_functions.py   # Tests customer creation functions
├── test_functions.py          # Tests general utility functions
├── test_update_function.py    # Tests customer update functions
└── verify_functions.py        # Verifies all database functions are working
```

## 🚀 Running Tests

### Run All Tests
```bash
cd /home/justin/.openclaw/workspace/github/agent_swarm
python3 -m pytest scripts/tests/ -v
```

### Run Individual Test Files
```bash
# Test the main agent
python3 scripts/tests/test_agent.py

# Test customer creation
python3 scripts/tests/test_create_functions.py

# Test general functions
python3 scripts/tests/test_functions.py

# Test customer updates
python3 scripts/tests/test_update_function.py

# Verify all functions
python3 scripts/tests/verify_functions.py
```

### Run Specific Test Cases
```bash
python3 -m pytest scripts/tests/test_agent.py::test_add_customer -v
python3 -m pytest scripts/tests/test_functions.py::test_normalize_phone -v
```

### Run with Coverage
```bash
python3 -m pytest scripts/tests/ --cov=blueprint --cov-report=html
```

## 📋 Test Descriptions

### `test_agent.py` - Main Agent Tests
**Purpose:** Validates the core bot functionality

**Test Cases:**
- `test_add_customer`: Verifies customer creation workflow
- `test_update_customer`: Tests customer modification
- `test_search_customers`: Validates fuzzy search functionality
- `test_conversation_memory`: Checks conversation persistence
- `test_tool_calling`: Validates dynamic tool composition

**Prerequisites:**
- Database must be set up with functions
- Test database connection configured

### `test_create_functions.py` - Customer Creation Tests
**Purpose:** Validates the `add_customer()` SQL function

**Test Cases:**
- `test_add_customer_with_email`: Customer with email only
- `test_add_customer_with_phone`: Customer with phone only
- `test_add_customer_with_both`: Customer with email and phone
- `test_add_customer_invalid_email`: Validates email format checking
- `test_add_customer_duplicate`: Handles duplicate detection

**Expected Behavior:**
- Returns customer ID on success
- Returns error message on failure
- Normalizes phone numbers to E.164 format
- Lowercases email addresses

### `test_functions.py` - Utility Function Tests
**Purpose:** Tests general utility functions

**Test Cases:**
- `test_normalize_phone`: Phone number normalization
- `test_normalize_email`: Email normalization
- `test_validate_phone`: Phone validation logic
- `test_validate_email`: Email validation logic
- `test_search_customers_fuzzy`: Fuzzy search accuracy

**Input/Output Examples:**
```python
# Phone normalization
normalize_phone("(555) 123-4567") → "+15551234567"
normalize_phone("555-123-4567") → "+15551234567"
normalize_phone("+44 20 7946 0958") → "+442079460958"

# Email normalization
normalize_email("John.Doe@Example.COM") → "john.doe@example.com"
```

### `test_update_function.py` - Customer Update Tests
**Purpose:** Validates the `update_customer()` SQL function

**Test Cases:**
- `test_update_customer_name`: Updates customer name
- `test_update_customer_email`: Updates email address
- `test_update_customer_phone`: Updates phone number
- `test_update_customer_address`: Updates full address
- `test_update_nonexistent_customer`: Handles missing customers
- `test_update_with_validation`: Validates input before update

**Expected Behavior:**
- Returns number of rows affected
- Returns error for non-existent customers
- Maintains audit trail of changes
- Validates data before updating

### `verify_functions.py` - Function Verification
**Purpose:** Comprehensive verification of all database functions

**Verification Steps:**
1. Check if all expected functions exist in database
2. Test each function with sample data
3. Verify return types and formats
4. Check for proper error handling
5. Validate audit logging is working

**Output:**
```
✓ add_customer function exists
✓ update_customer function exists
✓ search_customers function exists
✓ All functions responding correctly
✓ Audit triggers active
✓ Verification complete: 15/15 passed
```

## 🔧 Test Configuration

### Environment Variables
```bash
export TEST_DATABASE_HOST=${POSTGRES_HOST:-localhost}
export TEST_DATABASE_PORT=${POSTGRES_PORT:-5432}
export TEST_DATABASE_NAME=${POSTGRES_DB:-agent_swarm_test}
export TEST_DATABASE_USER=${POSTGRES_USER:-postgres}
export TEST_DATABASE_PASSWORD=${POSTGRES_PASSWORD}
```

### Test Database Setup
```bash
# Create test database
psql -h "${POSTGRES_HOST:-localhost}" -U "${POSTGRES_USER:-postgres}" -c "CREATE DATABASE ${POSTGRES_DB:-agent_swarm_test};"

# Run schema
psql -h "${POSTGRES_HOST:-localhost}" -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-agent_swarm_test}" -f scripts/database/agent_swarm_schema.sql

# Run functions
python3 scripts/database/apply_functions.py
```

### Using `.env.test`
Create a `.env.test` file in the blueprint directory:
```env
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_DB=agent_swarm_test
POSTGRES_USER=postgres
POSTGRES_PASSWORD=your_test_password
ENVIRONMENT=test
```

## 📊 Test Output Examples

### Successful Run
```
============================= test session starts ==============================
platform linux -- Python 3.12.0
collected 15 items

scripts/tests/test_agent.py .....                                        [ 33%]
scripts/tests/test_create_functions.py ....                              [ 60%]
scripts/tests/test_functions.py ...                                      [ 80%]
scripts/tests/test_update_function.py ..                                 [ 93%]
scripts/tests/verify_functions.py .                                      [100%]

============================== 15 passed in 2.34s ==============================
```

### Failed Test Example
```
FAILED scripts/tests/test_create_functions.py::test_add_customer_invalid_email
AssertionError: Expected validation error for invalid email 'not-an-email'
```

## 🐛 Debugging Tests

### Run with Verbose Output
```bash
python3 -m pytest scripts/tests/ -v -s
```

### Run with Logging
```bash
python3 -m pytest scripts/tests/ -v --log-cli-level=DEBUG
```

### Run Single Test in Isolation
```bash
python3 -c "
import test_agent
test_agent.test_add_customer()
"
```

### Check Database State
```bash
# View test data
psql -h "${POSTGRES_HOST:-localhost}" -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-agent_swarm_test}" -c "SELECT * FROM customers LIMIT 5;"

# Check audit log
psql -h "${POSTGRES_HOST:-localhost}" -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-agent_swarm_test}" -c "SELECT * FROM audit_log ORDER BY created_at DESC LIMIT 10;"
```

## ✅ Pre-Flight Checks

Before running tests, ensure:
1. ✅ Database is running and accessible
2. ✅ Schema is deployed (`agent_swarm_schema.sql`)
3. ✅ Functions are deployed (`apply_functions.py`)
4. ✅ Test data is loaded (optional but recommended)
5. ✅ Environment variables are set

## 🔄 CI/CD Integration

### GitHub Actions Example
```yaml
- name: Run Tests
  run: |
    pip install -r blueprint/requirements.txt
    python3 -m pytest scripts/tests/ -v --tb=short
```

### Pre-commit Hook
```bash
#!/bin/bash
python3 -m pytest scripts/tests/ -q
if [ $? -ne 0 ]; then
  echo "Tests failed, aborting commit"
  exit 1
fi
```

## 📚 Related Documentation

- [Database Scripts README](../database/README.md)
- [Blueprint Documentation](../../blueprint/README.md)
- [Customer Service Agent Requirements](../../docs/agent_requirements/customer_service/customer_service.md)
- [Attachment System](../../docs/attachments/ATTACHMENT_SYSTEM.md)

## 🤖 Agent Guidelines

When working with tests:
1. **Always run tests before committing changes** - Prevents breaking changes
2. **Add tests for new features** - Maintain test coverage
3. **Fix failing tests immediately** - Don't merge broken code
4. **Use descriptive test names** - Makes debugging easier
5. **Mock external services** - Keep tests isolated and fast

### Adding New Tests
```python
def test_new_feature():
    """
    Test description explaining what is being tested.
    
    Steps:
    1. Setup test data
    2. Execute the feature
    3. Verify expected outcome
    
    Expected:
    - Function returns correct value
    - Database is updated correctly
    - Audit log captures the change
    """
    # Arrange
    test_data = {...}
    
    # Act
    result = feature_function(test_data)
    
    # Assert
    assert result == expected_value
    # Additional assertions...
```

## 🎯 Test Coverage Goals

- **Customer Management**: 100% coverage
- **Database Functions**: 100% coverage
- **Agent Tools**: 90%+ coverage
- **Error Handling**: All error paths tested
- **Edge Cases**: Invalid inputs, duplicates, missing data
