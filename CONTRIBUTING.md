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
   pip install -r archive/blueprint/requirements.txt
   ```

4. **Bring up the database** - one command, and it is the only route that produces the schema the
   agents and the harnesses expect:
   ```bash
   ./scripts/db/db up        # container, TLS, roles, then every file in db/migrations/ in order
   ./scripts/db/db verify    # 37 structural assertions over the catalog you just built
   ./scripts/db/db seed      # db/seeds/*.sql - demo data, idempotent, no DDL
   ./scripts/db/db status    # what has been applied, and which container is running
   ```
   `db up` generates `dev/.env` with random local credentials (mode 600, gitignored) and writes an
   `AFPC_PG_HOST` line into each `agents/*/.env`, because the address the server certificate lists is a
   fact about your machine and not about this repository.

   **Do not apply `scripts/database/*.sql`, `archive/blueprint/*.sql`, or
   `docs/database/agent_first_erp_crm_schema.sql`.** They are the pre-`0001` copies the schema was
   ported *from* - `db/README.md` lists each one against the migration that superseded it - and several
   of their statements are qualified to `agent_first_erp_crm`, the schema
   `docs/database/DATABASE_REVIEW.md` 3.1 measured that no migration creates. Run them and you get a
   database where `SELECT * FROM vw_customers` answers and the rows a script wrote are invisible to
   every view, which is the symptom to recognise, not a bug to fix in the caller.

5. **Configure the agents** - the keys each process reads are in its own README:
   [`agents/customer_service/README.md`](agents/customer_service/README.md) and
   [`agents/inventory/README.md`](agents/inventory/README.md). There is no `archive/blueprint/.env.example` to
   copy: `archive/blueprint/` is the reference implementation, and it reads the variables its README names.

6. **Run the checks** - five things can be wrong independently, and each has its own harness:
   ```bash
   ./scripts/db/verify.sh                 # catalog structure, no fixtures
   ./scripts/db/test-functions.sh         # one probe per review finding, against a copy, residue-checked
   ./scripts/docs/check_agent_docs.sh     # that the documentation still describes the code
   cd agents/customer_service/backend_go && go test ./...
   ./scripts/agents/tool_testplan.sh      # one prompt per registered tool, verified against rows
   ```
   Do **not** run `pytest archive/blueprint/tests/` to check your work: two of its files commit DDL at import,
   against whichever database `POSTGRES_DB` names - which defaults to the live one. The warning is in
   [`archive/blueprint/tests/README.md`](archive/blueprint/tests/README.md), and the reason is in `AGENTS.md`'s Testing
   section.

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
feat(customer): make the email lookup a door, not a LIKE

Adds lookup by email to the customer read path. One selector per call, because two
ILIKE clauses over one row set answer for whichever column matched first - the rule
0016's add_customer refuses on and 4_7 probes. The Python reference stays as it is:
substring, LIMIT 5, both matches returned.

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
from blueprint.tools.customer_lookup import get_customer_info   # the module and tool that exist

class TestCustomerLookup(unittest.TestCase):
    # The blueprint's tools are LangChain @tool objects, so a unit test calls the function
    # behind the decorator with .func - and it needs a live database, because the tool opens
    # its own psycopg2 connection per call (DB_CONFIG defaults to POSTGRES_DB=agent_first_erp_crm,
    # i.e. the real one). That dependency is why this repository checks this surface in SQL
    # (db/tests/4_7) and through a prompt (scripts/agents/tool_testplan.sh) rather than here.

    def test_lookup_by_name_returns_text(self):
        result = get_customer_info.func("Alice Nguyen")
        self.assertIsInstance(result, str)
        self.assertIn("Alice", result)

    def test_a_missing_customer_is_a_string_and_not_a_crash(self):
        # `WHERE name ILIKE %s ... LIMIT 5` -> "No customers found matching '...'", and an
        # exception is caught and returned as text too. The contract is a string either way,
        # so a lookup failure cannot become an unhandled error the model retries forever
        self.assertIsInstance(get_customer_info.func("Nobody Here"), str)
```

> **One behavioural difference to know before copying a blueprint tool into an agent.** The Python
> lookup is a substring `ILIKE` with `LIMIT 5`: a name that matches two customers returns *both*, and
> the model picks. The deployed `get_customer_info` takes one selector at a time and the write doors
> refuse an ambiguous selection with the candidates listed - that is 0016's and 0021's rule, and probe
> `4_4` asserts it. The blueprint reads; the deployment refuses to guess.

### Running Tests

The harnesses, and what each one is for:

```bash
# Structure: constraints, grants, policies, indexes - no fixtures, no data assumptions
./scripts/db/verify.sh

# Behaviour: one probe per review finding (db/tests/N_N_*.sql), run against a COPY of the
# database with a row-count residue check around it, and a CASE table that says which
# migration each verdict is supposed to close. This is also where the code:* markers report.
./scripts/db/test-functions.sh

# The agent loop, the tool wiring, the derivations - against fakes, no database
cd agents/customer_service/backend_go && go test ./...
cd agents/inventory/backend_go        && go test ./...

# Documentation vs surface: a tool in code and not in a README fails, and so does a view
# a page promises that pg_class has never heard of
./scripts/docs/check_agent_docs.sh

# Acceptance: what a human gets. One prompt per registered tool through POST /api/chat,
# each verified on three planes - the call happened, the state is real, the run recorded
./scripts/agents/tool_testplan.sh
```

`archive/blueprint/tests/` is not on this list on purpose. Its five files are import-time scripts, `grep -c
'def test_'` answers 0 for all of them, and two commit `CREATE FUNCTION` stubs over the customer doors.
The reference implementation's behaviour is asserted instead by `db/tests/` probes against the SQL those
tools call, and by `go test` against the loop that replaced them.

---

## Documentation

### Documentation Structure

- **README.md** - Project overview and what is deployed
- **architecture.md** - System architecture and agent roles (lower-case; on a case-sensitive filesystem
  `ARCHITECTURE.md` is a broken link, which is what this page said until someone tried to click it)
- **AGENTS.md** - the route map for an agent working in this repository, including the five harnesses
- **archive/blueprint/docs/** - Agent-friendly SQL documentation
- **docs/database/** - Database schema and reference documentation
- **docs/agent_requirements/** - what each role is specified to do, plus `agent_test_plan.md`, the
  acceptance plan every registered tool is proven by
- **agents/customer_service/** and **agents/inventory/** - the two **deployed** agents (Go backend,
  React UI, `:4550` and `:4560`). `archive/blueprint/` is the pattern they descend from, in one Python file

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