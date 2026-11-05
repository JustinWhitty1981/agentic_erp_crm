# Database Views - Execution Instructions

**Purpose:** These views simplify complex queries for both humans and agents.

**Status:** superseded, and the sentence here used to say "ready to execute when the database
connection is restored" - which was not a status but a wish, held for as long as nobody tried. The views
are in the database already: created by `db/migrations/0001_baseline_canonical_port.sql`, made tenancy-
aware by `0009`, with the interaction read path added by `0017` and `vw_currency_rates` by `0018`.
`scripts/08_create_views.sql` is one of the superseded copies `db/README.md` lists, and running it now
does not rewrite anything: its ten statements are qualified to `agent_first_erp_crm`, the schema review
3.1 measured no migration creates, so the first one answers `3F000 schema "agent_first_erp_crm" does not
exist` (measured). That is the reason this page's "ready to execute" never stopped being true and never
stopped being a wish.

The column lists on this page describe the same five-view shape `archive/blueprint/docs/views.md` carried, and
the same defect: `vw_item_movement_summary` listed with `sku`, `item_name`, `total_receipts`,
`total_shipments` and `net_change`, of which the live view has none. `archive/blueprint/docs/views.md` has been
regenerated from `pg_attribute` and is checked against it by `code:agent_docs_match_surface`; this page
is kept for its explanations, and its lists are not authoritative. Read `docs/database/views.md` for
the catalog.

---

## Views are already created - there is nothing to run

The block this section carried told a reader to `psql ... -f scripts/database/08_create_views.sql`. Do
not: that file is one of the superseded copies `db/README.md` lists file by file, and every statement in
it is qualified to `agent_first_erp_crm`, the schema that no migration creates - so it answers `3F000`
on the first one. Verified against this server's database, where the views already live:

```sql
-- which views exist, and in which schema
SELECT viewname FROM pg_views WHERE schemaname = 'public' AND viewname LIKE 'vw_%' ORDER BY 1;
-- 23 rows. Any other schema name in the answer means the twin-schema fork happened on this box;
-- see docs/database/DATABASE_REVIEW.md 3.1 before you fix it by hand.
```

If a *new* view is needed, it is a numbered migration in `db/migrations/` with a `GRANT` to both read
roles and `security_invoker = true` set after the create (0009's ordering), not a script a human runs.
`scripts/db/db verify` then asserts it is there.

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
SELECT * FROM vw_customer_communications_summary 
WHERE entity_id = 123 
ORDER BY started_at DESC;
```

### Get pending follow-ups sorted by priority
```sql
SELECT * FROM vw_pending_followups 
WHERE priority IN ('high', 'critical');
```

### Get communication stats for all customers
```sql
SELECT entity_name, total_communications, avg_sentiment 
FROM vw_entity_communication_stats 
WHERE entity_type = 'customer' 
ORDER BY total_communications DESC;
```

### Get recent activity
```sql
SELECT * FROM vw_recent_communications 
ORDER BY started_at DESC 
LIMIT 20;
```

### Get agent performance
```sql
SELECT * FROM vw_agent_activity_summary;
```

### Check item availability

The live columns, read off `pg_attribute`: `sku`, `name`, `warehouse_name`, `quantity_on_hand`,
`quantity_reserved`, `quantity_available`, `reorder_point`. There is no `item_name` and no
`stock_status` column - the pair this page's example carried, which is why it is shown fixed rather
than quoted:

```sql
SELECT sku, name, warehouse_name, quantity_available, reorder_point
FROM vw_item_availability
WHERE sku = 'IN-1000';        -- the ten seeded skus are IN-1000..IN-1007, FG-2000 and CON-3000
```

---

## ✅ Verification

Not "after executing the script" - nothing needed executing. The views are already in `public`, and the
query that answers that has to say `public`, because `'agent_first_erp_crm'` is the schema review 3.1
measured no migration creates and it returns **zero rows** on a correctly built database, which reads
exactly like "the views are missing":

```sql
SELECT viewname FROM pg_views WHERE schemaname = 'public' AND viewname LIKE 'vw_%' ORDER BY 1;
```

That answers **23 rows** today, and the authoritative list with a sentence per view is
[views.md](views.md) - regenerated from the catalog by `make docs-schema`, so it cannot drift the way
the hand-kept list below did. Two names this page promised are **not** in that answer and never were in
the canonical schema: `vw_entity_contact_details` and `vw_communication_timeline`, both defined only in
the superseded `archive/blueprint/08_create_views.sql`. Everything else the list names is real, and **twelve**
views the remediation added are absent from it: `vw_tool_calls` and `vw_tool_performance`'s companions
from 0017 (`vw_recent_interactions` and `vw_failed_interactions` are the two the page does carry), then
`vw_inventory_valuation`, `vw_item_availability`, `vw_item_movement_summary`, `vw_low_stock_alerts` and
`vw_currency_rates` from 0018, and the five register views - `vw_domain_vocabulary`, `vw_rls_status`,
`vw_timestamp_status`, `vw_idempotency_status`, `vw_audit_coverage` - plus `vw_index_redundancy`.

Expected views, as the page listed them in July 2026 (kept so the diff against the catalog is auditable):
- vw_customers · vw_customer_communications_summary · vw_recent_communications · vw_pending_followups
- vw_entity_communication_stats · vw_primary_contact_communications · vw_communication_thread
- vw_agent_activity_summary · ~~vw_entity_contact_details~~ *(never created)* ·
  ~~vw_communication_timeline~~ *(never created)* · vw_recent_interactions · vw_failed_interactions ·
  vw_tool_performance
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

**File:** `scripts/08_create_views.sql` - superseded; the live definitions are in `db/migrations/`
**Created:** July 11, 2026
**Status:** Superseded. The views exist; the script here does not create them and cannot.
