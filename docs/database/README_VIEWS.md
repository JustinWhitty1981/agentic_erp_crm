# Database Views - Execution Instructions

**Purpose:** These views simplify complex queries for both humans and agents.

**Status:** SQL script created at `scripts/08_create_views.sql`. Ready to execute when database connection is restored.

---

## 📋 Views to Create

Run the following command to create all views:

```bash
# Set environment variables first
export POSTGRES_HOST=localhost
export POSTGRES_PORT=5432
export POSTGRES_DB=agent_swarm
export POSTGRES_USER=postgres
export POSTGRES_PASSWORD=your_password

# Create views
psql -h "${POSTGRES_HOST}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -f scripts/database/08_create_views.sql
```

Or execute the SQL content directly in your database client.

---

## 🗂️ Available Views

### 1. `customers` (Backward Compatibility)
- **Purpose:** Maps new entities/contacts to legacy customers table
- **Use Case:** Legacy code compatibility
- **Fields:** id, name, email, phone, address, status, created_at, updated_at, embedding

### 2. `customer_communications_summary`
- **Purpose:** All communications for customers with full context
- **Use Case:** Agent queries, customer service dashboards
- **Key Fields:** entity_name, contact_name, communication_type, summary, outcome, priority, sentiment_label

### 3. `recent_communications`
- **Purpose:** Last 7 days of all communications
- **Use Case:** Activity feeds, monitoring
- **Key Fields:** entity_name, contact_name, communication_type, subject, summary, outcome

### 4. `pending_followups`
- **Purpose:** All communications requiring follow-up
- **Use Case:** Task lists, agent action items
- **Key Fields:** follow_up_date, follow_up_action, priority, entity_name, contact_name

### 5. `entity_communication_stats`
- **Purpose:** Aggregated communication metrics per entity
- **Use Case:** Customer health scores, engagement metrics
- **Key Fields:** total_communications, resolved_count, escalated_count, avg_sentiment, last_contact_date

### 6. `primary_contact_communications`
- **Purpose:** Communications only with primary contacts
- **Use Case:** Executive-level interaction tracking
- **Key Fields:** entity_name, primary_contact, contact_title, communication_type, outcome

### 7. `communication_thread_view`
- **Purpose:** Shows communication threading hierarchy
- **Use Case:** Reconstructing conversation flows
- **Key Fields:** parent_id, thread_root_id, entity_name, contact_name, communication_type

### 8. `agent_activity_summary`
- **Purpose:** Summary of activity per bot agent
- **Use Case:** Performance monitoring, workload balancing
- **Key Fields:** total_actions, unique_entities, resolved_count, avg_sentiment, last_activity

### 9. `v_recent_interactions`
- **Purpose:** Last 100 agent interactions with full trajectory
- **Use Case:** Debugging, reviewing agent behavior
- **Key Fields:** human_input, intent_classification, agent_thoughts, actions_taken, final_output, duration_ms

### 10. `v_failed_interactions`
- **Purpose:** All interactions that resulted in errors
- **Use Case:** Identifying and fixing agent issues
- **Key Fields:** human_input, actions_taken, error_message, timestamp

### 11. `v_tool_performance`
- **Purpose:** Tool usage statistics and error rates
- **Use Case:** Optimizing tool performance, identifying problematic tools
- **Key Fields:** tool_name, call_count, avg_duration_ms, error_count, error_rate

### 12. `audit_summary_view`
- **Purpose:** Daily aggregation of human-bot interactions
- **Use Case:** Reporting, compliance, usage analytics
- **Key Fields:** date, user_id, bot_id, total_sessions, total_actions, successful_actions, failed_actions

---

## 🚀 Usage Examples

### Get all communications for a specific customer
```sql
SELECT * FROM agent_swarm.customer_communications_summary 
WHERE entity_id = 123 
ORDER BY started_at DESC;
```

### Get pending follow-ups sorted by priority
```sql
SELECT * FROM agent_swarm.pending_followups 
WHERE priority IN ('high', 'critical');
```

### Get communication stats for all customers
```sql
SELECT entity_name, total_communications, avg_sentiment 
FROM agent_swarm.entity_communication_stats 
WHERE entity_type = 'customer' 
ORDER BY total_communications DESC;
```

### Get recent activity
```sql
SELECT * FROM agent_swarm.recent_communications 
ORDER BY started_at DESC 
LIMIT 20;
```

### Get agent performance
```sql
SELECT * FROM agent_swarm.agent_activity_summary;
```

---

## ✅ Verification

After executing the script, verify with:

```sql
SELECT viewname FROM pg_views 
WHERE schemaname = 'agent_swarm' 
ORDER BY viewname;
```

Expected views:
- agent_communications_summary
- agent_activity_summary
- customer_communications_summary
- customers
- entity_communication_stats
- pending_followups
- primary_contact_communications
- recent_communications
- communication_thread_view

---

## 📝 Notes

- Views are read-only (as expected for SQL views)
- All views include proper comments for documentation
- Views use LEFT JOINs to handle optional fields gracefully
- Performance is optimized with existing indexes on base tables

---

**File:** `scripts/08_create_views.sql`  
**Created:** July 11, 2026  
**Status:** Ready for execution
