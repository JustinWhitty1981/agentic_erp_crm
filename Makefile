# Agent First ERP CRM Makefile
#
# Every database target delegates to scripts/db/db, which holds the behaviour. Two
# implementations of the same operations drift apart, and this host has no `make`
# installed, so the dispatcher is the authoritative route and works on its own:
#
#   scripts/db/db up          scripts/db/db verify          scripts/db/db test
#
# Install make on Debian/Ubuntu with: sudo apt-get install make

DB := scripts/db/db

.PHONY: help setup test lint format test-coverage clean docs docs-schema \
        dev-up dev-init dev-status dev-down dev-destroy \
        db-migrate db-status db-verify db-test db-seed db-shell db-audit \
        db-backup db-fresh db-destroy

help:
	@$(DB) help
	@echo ""
	@echo "Development:"
	@echo "  make test / lint / format / docs / docs-schema / clean"

# ------------------------------------------------------------------ environment --
dev-up:
	@$(DB) up

dev-init:
	@$(DB) init

dev-status:
	@$(DB) status

dev-down:
	@$(DB) down

dev-destroy:
	@$(DB) destroy

# --------------------------------------------------------------------- database --
db-migrate:
	@$(DB) migrate

db-status:
	@$(DB) status

db-verify:
	@$(DB) verify

db-test:
	@$(DB) test

db-seed:
	@$(DB) seed

db-shell:
	@$(DB) shell

db-audit:
	@$(DB) audit

db-backup:
	@$(DB) backup

# Destroys and rebuilds. Gated, because this database is expected to persist.
db-fresh:
	@$(DB) fresh

# ------------------------------------------------------------------- code tasks --
setup:
	@echo "Setting up development environment..."
	@python3 -m venv venv
	@./venv/bin/pip install -r blueprint/requirements.txt
	@echo "Now run: scripts/db/db up"

test:
	@echo "Running tests..."
	@pytest blueprint/tests/ -v

test-coverage:
	@echo "Running tests with coverage..."
	@pytest blueprint/tests/ --cov=blueprint --cov-report=html --cov-report=term-missing

lint:
	@echo "Running linting checks..."
	@python3 -m pycodestyle blueprint/ --max-line-length=120
	@python3 -m pyflakes blueprint/

format:
	@echo "Formatting code..."
	@python3 -m black blueprint/ --line-length 120

docs:
	@echo "Documentation is located in:"
	@echo "  - db/README.md                      single source of truth for the schema"
	@echo "  - db/MIGRATIONS.md                  finding -> migration mapping"
	@echo "  - dev/README.md                     this development server, audit access"
	@echo "  - blueprint/docs/                   agent-friendly SQL documentation"
	@echo "  - docs/database/                    schema documentation and review"
	@echo "  - ARCHITECTURE_DECISION_RECORDS/     architecture decisions"

# Regenerated from the running catalog, so it cannot drift the way the hand-maintained schema.md did.
# The generator is scripts/docs/gen_schema_docs.sh rather than a recipe, and its header says why the
# recipe it replaced wrote empty files. Wired into CI in Phase 2 of the remediation plan (T3).
docs-schema:
	@scripts/docs/gen_schema_docs.sh

clean:
	@echo "Cleaning temporary files..."
	@find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	@find . -type d -name "*.pyc" -delete 2>/dev/null || true
	@find . -type d -name ".pytest_cache" -exec rm -rf {} + 2>/dev/null || true
	@rm -rf htmlcov/ .coverage 2>/dev/null || true
	@echo "Cleanup complete."
