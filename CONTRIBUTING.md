# Contributing to Agent First ERP CRM

Thank you for your interest in contributing to Agent First ERP CRM! This document provides guidelines and instructions for contributing to the project.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Pull Request Process](#pull-request-process)
- [Coding Standards](#coding-standards)
- [Testing Guidelines](#testing-guidelines)
- [Documentation](#documentation)

---

## Code of Conduct

- Be respectful and inclusive
- Provide constructive feedback
- Accept constructive criticism
- Focus on what is best for the community

---

## Getting Started

### Prerequisites

- Python 3.11 or higher
- PostgreSQL 16 or higher
- Docker and Docker Compose (for containerized development)
- Git

### Setup Development Environment

1. **Fork the repository**

2. **Clone your fork**
   ```bash
   git clone https://github.com/your-username/agent_first_erp_crm.git
   cd agent_first_erp_crm
   ```

3. **Set up Python environment**
   ```bash
   python -m venv venv
   source venv/bin/activate  # On Windows: venv\Scripts\activate
   pip install -r blueprint/requirements.txt
   ```

4. **Configure environment variables**
   ```bash
   cp blueprint/.env.example blueprint/.env
   # Edit blueprint/.env with your database credentials
   ```

5. **Set up PostgreSQL database**
   ```bash
   # Create the database
   createdb agent_first_erp_crm
   
   # Apply schema
   psql -d agent_first_erp_crm -f scripts/database/agent_first_erp_crm_schema.sql
   psql -d agent_first_erp_crm -f scripts/database/08_create_views.sql
   psql -d agent_first_erp_crm -f scripts/database/09_customer_functions.sql
   psql -d agent_first_erp_crm -f scripts/database/10_audit_log.sql
   psql -d agent_first_erp_crm -f scripts/database/11_interaction_logging.sql
   ```

6. **Run tests**
   ```bash
   pytest blueprint/tests/ -v
   ```

---

## Development Workflow

### Branch Naming Convention

- `feature/description` - New features
- `bugfix/description` - Bug fixes
- `docs/description` - Documentation changes
- `refactor/description` - Code refactoring
- `chore/description` - Maintenance tasks

### Commit Message Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, etc.)
- `refactor`: Code refactoring
- `test`: Test additions or modifications
- `chore`: Maintenance tasks

**Example:**
```
feat(customer): add search by email function

Added search_customers_by_email function to enable
lookup of customers by their email address.

Closes #123
```

---

## Pull Request Process

### Before Submitting

1. **Update documentation** - Add or update relevant documentation
2. **Add tests** - Ensure your changes are covered by tests
3. **Run all tests** - Make sure all tests pass
4. **Check code style** - Follow PEP 8 guidelines
5. **Update CHANGELOG** - Add your changes to the changelog

### PR Template

```markdown
## Description
<!-- Describe your changes in detail -->

## Related Issues
<!-- Link any related issues -->
- Closes #

## Type of Change
<!-- Mark the appropriate option with an "x" -->
- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Documentation update
- [ ] Refactoring
- [ ] Performance improvement
- [ ] Test improvements

## Testing
<!-- Describe how you tested your changes -->

## Checklist
- [ ] My code follows the project's coding standards
- [ ] I have added tests that prove my fix/feature works
- [ ] I have updated the documentation accordingly
- [ ] All new and existing tests passed
```

---

## Coding Standards

### Python

- Follow [PEP 8](https://pep8.org/) style guide
- Use type hints for function signatures
- Write docstrings for all public functions and classes
- Keep functions focused and single-purpose
- Use meaningful variable and function names

### SQL

- Use `snake_case` for table and column names
- Use proper indentation (2 spaces)
- Add comments for complex queries
- Use parameterized queries to prevent SQL injection

### Documentation

- Write clear and concise documentation
- Include examples where appropriate
- Keep documentation up to date with code changes
- Use Markdown for all documentation files

---

## Testing Guidelines

### Writing Tests

1. **Test file naming**: `test_<module>.py`
2. **Test function naming**: `test_<function>_<scenario>.py`
3. **Use descriptive test names** that explain what is being tested

### Test Structure

```python
import unittest
from blueprint.tools.customer_tools import get_customer_by_id

class TestCustomerLookup(unittest.TestCase):
    
    def test_get_customer_by_id_returns_customer(self):
        """Test that get_customer_by_id returns a customer."""
        result = get_customer_by_id(1)
        self.assertIsNotNone(result)
        self.assertIn('name', result)
    
    def test_get_customer_by_id_not_found(self):
        """Test that get_customer_by_id handles missing customers."""
        result = get_customer_by_id(99999)
        self.assertIsNone(result)
```

### Running Tests

```bash
# Run all tests
pytest blueprint/tests/ -v

# Run specific test file
pytest blueprint/tests/test_functions.py -v

# Run with coverage
pytest blueprint/tests/ --cov=blueprint --cov-report=html

# Run with verbose output
pytest blueprint/tests/ -v -s
```

---

## Documentation

### Documentation Structure

- **README.md** - Project overview and quick start guide
- **ARCHITECTURE.md** - System architecture and design decisions
- **blueprint/docs/** - Agent-friendly SQL documentation
- **docs/database/** - Database schema and reference documentation
- **docs/agent_requirements/** - Domain-specific agent requirements

### Documentation Guidelines

1. **Keep it current** - Update documentation with code changes
2. **Be specific** - Include examples and use cases
3. **Use clear language** - Avoid jargon where possible
4. **Link to related docs** - Help readers find related information

---

## Questions or Need Help?

- Check existing [issues](https://github.com/your-repo/issues)
- Open a new issue for questions or problems
- Join our community discussions

---

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

*Thank you for contributing to Agent First ERP CRM!*