# Quick Start Guide - Agent First ERP CRM

## 📚 Before You Start

For AI agents working on this project, see **[AGENTS.md](../AGENTS.md)** for complete navigation guidance.

## Prerequisites
- Docker installed and running
- PostgreSQL at `{your-postgres-host}:5432` (database: `agent_first_erp_crm`)
- Ollama running with `ornith:35b` at `http://{your-ollama-host}:11434`
- Telegram bot token

## Step 1: Verify Database Schema

Check that the database is migrated — `agent_first_erp_crm` is a **database** name, never a schema: review 3.1 measured that no migration creates a schema by that name, so a `pg_namespace` query for it is the wrong test. The right one::
```bash
psql -h {your-postgres-host} -U agent_first_erp_crm -d agent_first_erp_crm -c "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'agent_first_erp_crm';"
```

If the tables are missing, **do not** run `setup_sample_data.sql` — its first statement is
`CREATE SCHEMA agent_first_erp_crm` and its tables land inside that schema, which no migration creates and
no `vw_*` view reads through. Build the database the supported way:
```bash
../scripts/db/db up && ../scripts/db/db seed
```

## Step 2: Configure Environment

Edit `blueprint/.env` with your settings:
```bash
TELEGRAM_BOT_TOKEN=your_bot_token_here
OLLAMA_BASE_URL=http://{your-ollama-host}:11434
OLLAMA_MODEL=ornith:35b
POSTGRES_HOST={your-postgres-host}
POSTGRES_PORT=5432
POSTGRES_DB=agent_first_erp_crm
POSTGRES_USER=agent_first_erp_crm
POSTGRES_PASSWORD={yourpasswordhere}
```

## Step 3: Build and Run

```bash
cd blueprint
docker-compose up --build -d
```

**Note:** This assumes you're in the `agent_first_erp_crm` root directory. Adjust the path as needed for your environment.

## Step 4: Check Logs

```bash
docker-compose logs -f
```

You should see:
```
Starting customer service bot...
Using Ollama model: <OLLAMA_MODEL>
Bot is running! Waiting for messages...
```

## Step 5: Test the Bot

Send these messages to your Telegram bot:

1. **Customer Lookup:**
   ```
   Tell me about Alice Johnson
   ```

2. **Communications History:**
   ```
   What's the recent communication history for Alice Johnson?
   ```

3. **Entity Statistics:**
   ```
   Show me stats for Alice Johnson
   ```

4. **Log a Communication:**
   ```
   I just spoke with Alice Johnson about their order. Summary: Discussed shipping timeline for order ORD-10001.
   ```

5. **Current Time:**
   ```
   What time is it?
   ```

## Step 6: Verify Database Updates

After logging a communication, check the database:
```bash
psql -h {your-postgres-host} -U agent_first_erp_crm -d agent_first_erp_crm -c "SELECT * FROM vw_recent_communications WHERE entity_name ILIKE '%Alice%' ORDER BY started_at DESC LIMIT 5;"
```

## Troubleshooting

### Database Connection Error
- Verify PostgreSQL is running: `docker ps | grep postgres`
- Check credentials in `.env` match your PostgreSQL setup
- Ensure the database is migrated (`../scripts/db/verify.sh` answers 37 checks)

### Ollama Connection Error
- Verify Ollama is running: `curl http://{your-ollama-host}:11434/api/tags`
- Ensure `ornith:35b` is pulled: `ollama pull ornith:35b`
- Check firewall allows connections from Docker

### Telegram Bot Not Responding
- Verify bot token is correct
- Check bot logs: `docker-compose logs -f`
- Ensure bot has been started in Telegram (send `/start`)

> **The model line, for honesty.** This reference implementation talks to **Ollama**
> (`ChatOllama`; the env keys are `OLLAMA_MODEL`, default `ornith:35b`, and `OLLAMA_BASE_URL`, whose
> in-code default is the literal placeholder `http://{your-ollama-url}:11434` - unset it and the
> blueprint cannot reach a model, which is worth knowing before assuming a connection bug). The deployed Go
> agents do not: they call an OpenAI-compatible **vLLM** endpoint (`LLM_PROVIDER=local`,
> `VLLM_BASE_URL`, `VLLM_MODEL`) - `../architecture.md` 6.1 has the current values and `curl
> localhost:4550/api/health | jq` prints what a running process actually believes. The loop is the same;
> only the endpoint behind it differs.

## Next Steps

1. **Review the Blueprint:** Read [bot.py](bot.py) to understand the pattern
2. **Study the Architecture:** Read [architecture.md](../architecture.md) for system design
3. **Understand the Blueprint Pattern:** Read [AGENT_SUMMARY.md](AGENT_SUMMARY.md)
4. **Plan New Agents:** Review [PLAN.md](../PLAN.md) for development roadmap
5. **Database Documentation:** See [docs/database/](../docs/database/) for schema reference
6. **Add CAO Validation:** Build the validation layer for agent actions

---

*Keep it simple. One agent at a time. Follow the blueprint.*
