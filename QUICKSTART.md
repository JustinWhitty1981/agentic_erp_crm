# Quick Start Guide - Agent First ERP CRM

## Prerequisites
- Docker installed and running
- PostgreSQL at `{your-database-host}:{your-database-port}` (database: `{your-database-name}`)
- Ollama running with `{your-llm-model}` at `{your-ollama-url}`
- Telegram bot token

## Step 1: Verify Database Schema

Check if the `agent_first_erp_crm` schema exists:
```bash
psql -h {your-database-host} -U {your-username} -d {your-database-name} -c "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'agent_first_erp_crm';"
```

If it doesn't exist, create it and run the sample data:
```bash
psql -h {your-database-host} -U {your-username} -d {your-database-name} -f docs/database/setup_sample_data.sql
```

## Step 2: Configure Environment

Edit `blueprint/.env` with your settings:
```bash
TELEGRAM_BOT_TOKEN=your_bot_token_here
OLLAMA_BASE_URL={your-ollama-url}
OLLAMA_MODEL={your-llm-model}
POSTGRES_HOST={your-database-host}
POSTGRES_PORT={your-database-port}
POSTGRES_DB={your-database-name}
POSTGRES_USER={your-username}
POSTGRES_PASSWORD={your-password}
```

## Step 3: Build and Run

```bash
cd blueprint
docker-compose up --build -d
```

## Step 4: Check Logs

```bash
docker-compose logs -f
```

You should see:
```
Starting Customer Service Bot with model: {your-llm-model} at {your-ollama-url}
Listening for messages...
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
psql -h {your-database-host} -U {your-username} -d {your-database-name} -c "SELECT * FROM agent_first_erp_crm.recent_communications WHERE entity_name ILIKE '%Alice%' ORDER BY started_at DESC LIMIT 5;"
```

## Troubleshooting

### Database Connection Error
- Verify PostgreSQL is running: `docker ps | grep postgres`
- Check credentials in `.env` match your PostgreSQL setup
- Ensure `agent_first_erp_crm` schema exists

### Ollama Connection Error
- Verify Ollama is running: `curl {your-ollama-url}/api/tags`
- Ensure `{your-llm-model}` is pulled: `ollama pull {your-llm-model}`
- Check firewall allows connections from Docker

### Telegram Bot Not Responding
- Verify bot token is correct
- Check bot logs: `docker-compose logs -f`
- Ensure bot has been started in Telegram (send `/start`)

## Next Steps

1. **Review the Blueprint:** Read `blueprint/bot.py` to understand the pattern
2. **Study the Architecture:** Read `architecture.md` for system design
3. **Plan New Agents:** Review `PLAN.md` for development roadmap
4. **Add CAO Validation:** Build the validation layer for agent actions

---

*Keep it simple. One agent at a time. Follow the blueprint.*
