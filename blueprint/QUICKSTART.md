# Quick Start Guide - Agent Swarm

## 📚 Before You Start

For AI agents working on this project, see **[AGENTS.md](AGENTS.md)** for complete navigation guidance.

## Prerequisites
- Docker installed and running
- PostgreSQL at `{your-postgres-host}:5432` (database: `jarvis_data`)
- Ollama running with `ornith:35b` at `http://{your-ollama-host}:11434`
- Telegram bot token

## Step 1: Verify Database Schema

Check if the `agent_swarm` schema exists:
```bash
psql -h {your-postgres-host} -U jarvis -d jarvis_data -c "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'agent_swarm';"
```

If it doesn't exist, create it and run the sample data:
```bash
psql -h {your-postgres-host} -U jarvis -d jarvis_data -f blueprint/setup_sample_data.sql
```

## Step 2: Configure Environment

Edit `blueprint/.env` with your settings:
```bash
TELEGRAM_BOT_TOKEN=your_bot_token_here
OLLAMA_BASE_URL=http://{your-ollama-host}:11434
OLLAMA_MODEL=ornith:35b
POSTGRES_HOST={your-postgres-host}
POSTGRES_PORT=5432
POSTGRES_DB=jarvis_data
POSTGRES_USER=jarvis
POSTGRES_PASSWORD={yourpasswordhere}
```

## Step 3: Build and Run

```bash
cd blueprint
docker-compose up --build -d
```

**Note:** This assumes you're in the `agent_swarm` root directory. Adjust the path as needed for your environment.

## Step 4: Check Logs

```bash
docker-compose logs -f
```

You should see:
```
Starting Customer Service Bot with model: ornith:35b at http://{your-ollama-host}:11434
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
psql -h {your-postgres-host} -U jarvis -d jarvis_data -c "SELECT * FROM agent_swarm.recent_communications WHERE entity_name ILIKE '%Alice%' ORDER BY started_at DESC LIMIT 5;"
```

## Troubleshooting

### Database Connection Error
- Verify PostgreSQL is running: `docker ps | grep postgres`
- Check credentials in `.env` match your PostgreSQL setup
- Ensure `agent_swarm` schema exists

### Ollama Connection Error
- Verify Ollama is running: `curl http://{your-ollama-host}:11434/api/tags`
- Ensure `ornith:35b` is pulled: `ollama pull ornith:35b`
- Check firewall allows connections from Docker

### Telegram Bot Not Responding
- Verify bot token is correct
- Check bot logs: `docker-compose logs -f`
- Ensure bot has been started in Telegram (send `/start`)

## Next Steps

1. **Review the Blueprint:** Read [blueprint/bot.py](blueprint/bot.py) to understand the pattern
2. **Study the Architecture:** Read [architecture.md](architecture.md) for system design
3. **Understand the Blueprint Pattern:** Read [blueprint/AGENT_SUMMARY.md](blueprint/AGENT_SUMMARY.md)
4. **Plan New Agents:** Review [PLAN.md](PLAN.md) for development roadmap
5. **Database Documentation:** See [docs/database/](docs/database/) for schema reference
6. **Add CAO Validation:** Build the validation layer for agent actions

---

*Keep it simple. One agent at a time. Follow the blueprint.*
