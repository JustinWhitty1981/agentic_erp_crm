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
export POSTGRES_DB=agent_first_erp_crm
export POSTGRES_USER=postgres
export POSTGRES_PASSWORD=your_password

# Create views
psql -h "${POSTGRES_HOST}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -f scripts/database/08_create_views.sql
```

Or execute the SQL content directly in your database client.

---

## 🗂️ Available Views

### 1. `vw_customers` (Backward Compatibility)
- **Purpose:** Maps new entities/contacts to legacy customers table
- **Use Case:** Legacy code compatibility
- **Fields:** id, name, email, phone, address, status, created_at, updated_at, embedding

### 2. `vw_customer_communications_summary`
- **Purpose:** All communications for customers with full context
- **Use Case:** Agent queries, customer service dashboards
- **Key Fields:** entity_name, contact_name, communication_type, summary, outcome, priority, sentiment_label

### 3. `vw_recent_communications`
- **Purpose:** Last 7 days of all communications
- **Use Case:** Activity feeds, monitoring
- **Key Fields:** entity_name, contact_name, communication_type, subject, summary, outcome

### 4. `vw_pending_followups`
- **Purpose:** All communications requiring follow-up
- **Use Case:** Task lists, agent action items
- **Key Fields:** follow_up_date, follow_up_action, priority, entity_name, contact_name

### 5. `vw_entity_communication_stats`
- **Purpose:** Aggregated communication metrics per entity
- **Use Case:** Customer health scores, engagement metrics
- **Key Fields:** total_communications, resolved_count, escalated_count, avg_sentiment, last_contact_date

### 6. `vw_primary_contact_communications`
- **Purpose:** Communications only with primary contacts
- **Use Case:** Executive-level interaction tracking
- **Key Fields:** entity_name, primary_contact, contact_title, communication_type, outcome

### 7. `vw_communication_thread`
- **Purpose:** Shows communication threading hierarchy
- **Use Case:** Reconstructing conversation flows
- **Key Fields:** parent_id, thread_root_id, entity_name, contact_name, communication_type

### 8. `vw_agent_activity_summary`
- **Purpose:** Summary of activity per bot agent
- **Use Case:** Performance monitoring, workload balancing
- **Key Fields:** total_actions, unique_entities, resolved_count, avg_sentiment, last_activity

### 9. `vw_recent_interactions`
- **Purpose:** Last 100 agent interactions with full trajectory
- **Use Case:** Debugging, reviewing agent behavior
- **Key Fields:** human_input, intent_classification, agent_thoughts, actions_taken, final_output, duration_ms

### 10. `vw_failed_interactions`
- **Purpose:** All interactions that resulted in errors
- **Use Case:** Identifying and fixing agent issues
- **Key Fields:** human_input, actions_taken, error_message, timestamp

### 11. `vw_tool_performance`
- **Purpose:** Tool usage statistics and error rates
- **Use Case:** Optimizing tool performance, identifying problematic tools
- **Key Fields:** tool_name, call_count, avg_duration_ms, error_count, error_rate

### 12. `vw_inventory_valuation`
- **Purpose:** Inventory value by warehouse/category
- **Use Case:** Financial reporting
- **Key Fields:** warehouse_name, category_name, total_value, item_count

### 13. `vw_item_availability`
- **Purpose:** Stock levels across warehouses
- **Use Case:** Checking item availability
- **Key Fields:** sku, item_name, warehouse_name, quantity_on_hand, stock_status

### 14. `vw_item_movement_summary`
- **Purpose:** 30-day movement patterns
- **Use Case:** Analyzing item movement
- **Key Fields:** sku, item_name, total_receipts, total_shipments, net_change

### 15. `vw_low_stock_alerts`
- **Purpose:** Items below reorder point
- **Use Case:** Replenishment tasks
- **Key Fields:** sku, item_name, warehouse_name, quantity_available, reorder_point

### 16. `vw_entity_contact_details`
- **Purpose:** Complete entity and contact details
- **Use Case:** Full customer information lookup
- **Key Fields:** entity_id, entity_name, contact_id, contact_name, email, phone, address

### 17. `vw_communication_timeline`
- **Purpose:** Chronological view with full context
- **Use Case:** Timeline-based communication review
- **Key Fields:** started_at, entity_name, contact_name, communication_type, summary, outcome

---

## 🚀 Usage Examples

### Get all communications for a specific customer
```sql
SELECT * FROM agent_first_erp_crm.vw_customer_communications_summary 
WHERE entity_id = 123 
ORDER BY started_at DESC;
```

### Get pending follow-ups sorted by priority
```sql
SELECT * FROM agent_first_erp_crm.vw_pending_followups 
WHERE priority IN ('high', 'critical');
```

### Get communication stats for all customers
```sql
SELECT entity_name, total_communications, avg_sentiment 
FROM agent_first_erp_crm.vw_entity_communication_stats 
WHERE entity_type = 'customer' 
ORDER BY total_communications DESC;
```

### Get recent activity
```sql
SELECT * FROM agent_first_erp_crm.vw_recent_communications 
ORDER BY started_at DESC 
LIMIT 20;
```

### Get agent performance
```sql
SELECT * FROM agent_first_erp_crm.vw_agent_activity_summary;
```

### Check item availability
```sql
SELECT sku, item_name, warehouse_name, quantity_available, stock_status
FROM agent_first_erp_crm.vw_item_availability
WHERE sku = 'WIDGET-A';
```

---

## ✅ Verification

After executing the script, verify with:

```sql
SELECT viewname FROM pg_views 
WHERE schemaname = 'agent_first_erp_crm' 
ORDER BY viewname;
```

Expected views:
- vw_customers
- vw_customer_communications_summary
- vw_recent_communications
- vw_pending_followups
- vw_entity_communication_stats
- vw_primary_contact_communications
- vw_communication_thread
- vw_agent_activity_summary
- vw_entity_contact_details
- vw_communication_timeline
- vw_recent_interactions
- vw_failed_interactions
- vw_tool_performance
- vw_inventory_valuation
- vw_item_availability
- vw_item_movement_summary
- vw_low_stock_alerts

---

## 📝 Notes

- **Naming Convention:** All views MUST use the `vw_` prefix (e.g., `vw_customers`, `vw_pending_followups`)
- Views are read-only (as expected for SQL views)
- All views include proper comments for documentation
- Views use LEFT JOINs to handle optional fields gracefully
- Performance is optimized with existing indexes on base tables

---

**File:** `scripts/08_create_views.sql`  
**Created:** July 11, 2026  
**Status:** Ready for execution
