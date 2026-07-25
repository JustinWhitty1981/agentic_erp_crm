# Agent First ERP CRM Makefile
# Common development tasks

.PHONY: help setup test lint clean db-create db-migrate db-seed

# Default target
help:
	@echo "Agent First ERP CRM - Available Commands"
	@echo ""
	@echo "Setup:"
	@echo "  make setup          - Set up development environment"
	@echo "  make db-create      - Create PostgreSQL database"
	@echo "  make db-migrate     - Apply database schema"
	@echo "  make db-seed        - Load sample data"
	@echo ""
	@echo "Development:"
	@echo "  make test           - Run all tests"
	@echo "  make test-coverage  - Run tests with coverage report"
	@echo "  make lint           - Run linting checks"
	@echo "  make format         - Format code"
	@echo ""
	@echo "Database:"
	@echo "  make db-reset       - Reset database (WARNING: destroys data)"
	@echo "  make db-backup      - Backup database"
	@echo "  make db-restore     - Restore database from backup"
	@echo ""
	@echo "Documentation:"
	@echo "  make docs           - Generate documentation"
	@echo "  make docs-schema    - Generate schema documentation"
	@echo ""
	@echo "Cleanup:"
	@echo "  make clean          - Clean temporary files"

# Setup development environment
setup:
	@echo "Setting up development environment..."
	@python3 -m venv venv
	@source venv/bin/activate && pip install -r blueprint/requirements.txt
	@echo "Setup complete. Run 'source venv/bin/activate' to activate the virtual environment."

# Create PostgreSQL database
db-create:
	@echo "Creating database 'agent_first_erp_crm'..."
	@createdb agent_first_erp_crm || echo "Database may already exist"

# Apply database schema
db-migrate:
	@echo "Applying database schema..."
	@psql -d agent_first_erp_crm -f scripts/database/agent_first_erp_crm_schema.sql
	@psql -d agent_first_erp_crm -f scripts/database/08_create_views.sql
	@psql -d agent_first_erp_crm -f scripts/database/09_customer_functions.sql
	@psql -d agent_first_erp_crm -f scripts/database/10_audit_log.sql
	@psql -d agent_first_erp_crm -f scripts/database/11_interaction_logging.sql
	@echo "Schema migration complete."

# Load sample data
db-seed:
	@echo "Loading sample data..."
	@psql -d agent_first_erp_crm -f scripts/database/setup_sample_data.sql
	@echo "Sample data loaded."

# Run all tests
test:
	@echo "Running tests..."
	@pytest blueprint/tests/ -v

# Run tests with coverage
test-coverage:
	@echo "Running tests with coverage..."
	@pytest blueprint/tests/ --cov=blueprint --cov-report=html --cov-report=term-missing

# Run linting
lint:
	@echo "Running linting checks..."
	@python3 -m pycodestyle blueprint/ --max-line-length=120
	@python3 -m pyflakes blueprint/

# Format code
format:
	@echo "Formatting code..."
	@python3 -m black blueprint/ --line-length 120

# Reset database (WARNING: destroys all data)
db-reset:
	@echo "WARNING: This will destroy all data in the database!"
	@read -p "Are you sure? (y/N) " confirm && [ "$$confirm" = "y" ] || exit 1
	@dropdb agent_first_erp_crm || true
	@createdb agent_first_erp_crm
	@make db-migrate

# Backup database
db-backup:
	@echo "Backing up database to backup/agent_first_erp_crm_$$(date +%Y%m%d_%H%M%S).sql..."
	@mkdir -p backup
	@pg_dump agent_first_erp_crm > backup/agent_first_erp_crm_$$(date +%Y%m%d_%H%M%S).sql

# Restore database from backup
db-restore:
	@echo "Restoring database from backup..."
	@read -p "Enter backup file name: " backup_file && \
		psql agent_first_erp_crm < backup/$$backup_file

# Generate documentation
docs:
	@echo "Generating documentation..."
	@echo "Documentation is located in:"
	@echo "  - blueprint/docs/ (agent-friendly SQL documentation)"
	@echo "  - docs/database/ (database schema documentation)"
	@echo "  - ARCHITECTURE_DECISION_RECORDS/ (architecture decisions)"

# Generate schema documentation using pgschema
docs-schema:
	@echo "Generating schema documentation with pgschema..."
	@pip install pgschema
	@pgschema dump -h localhost -U postgres -d agent_first_erp_crm -o docs/schema/
	@pgschema graph -h localhost -U postgres -d agent_first_erp_crm > schema_graph.dot

# Clean temporary files
clean:
	@echo "Cleaning temporary files..."
	@find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	@find . -type d -name "*.pyc" -delete 2>/dev/null || true
	@find . -type d -name ".pytest_cache" -exec rm -rf {} + 2>/dev/null || true
	@find . -type d -name ".mypy_cache" -exec rm -rf {} + 2>/dev/null || true
	@rm -rf htmlcov/ .coverage 2>/dev/null || true
	@rm -rf .tmp/* 2>/dev/null || true
	@echo "Cleanup complete."