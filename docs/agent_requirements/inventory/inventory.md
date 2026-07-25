# Inventory Agent Requirements

## Core Identity
- **Role:** Monitor stock levels and alert on shortages.
- **Schedule:** Runs every 30 minutes (via Cron).
- **Database Access:** Read/Write to `products`, `stock_levels`, `orders`.
- **Implementation Pattern:** Follows the blueprint pattern (adapted for scheduled/cron execution).

## Functional Requirements
1.  **Stock Monitoring:**
    - Query all products where `current_stock < minimum_order_quantity`.
    - Calculate days of stock remaining based on average daily sales (last 30 days).
    - Identify trends: "Stock is dropping faster than usual."
2.  **Alerting:**
    - Generate an alert if stock is critical (e.g., < 3 days supply).
    - Format alerts for the CAO: "Product X is low. Current: Y. Min: Z. Suggested reorder: [Quantity]."
    - Send alerts via Telegram to the business owner.
3.  **Reporting:**
    - Generate a daily summary of low-stock items.
    - Log all checks to the `audit_log`.
    - Provide a weekly trend report (stock levels over time).

## Non-Functional Requirements
- **Reliability:** Must run successfully every 30 minutes.
- **Efficiency:** Query must be optimized for large product catalogs (use indexes).
- **Safety:** Read-only access to `products` and `stock_levels`. No write access to `orders` (unless explicitly configured for auto-reorder).
- **Scalability:** Must handle 10,000+ products without performance degradation.

## Implementation Notes

### Blueprint Adaptation
The inventory agent will follow the blueprint pattern with modifications for scheduled execution:

```python
# Instead of Telegram bot, use cron-triggered script
def main():
    agent = build_agent()
    check_stock_levels(agent)
    send_alerts_if_needed()
    log_check_to_audit()
```

### Tools Required
| Tool | Purpose | Database Query |
|------|---------|----------------|
| `get_low_stock_products` | Find items below threshold | `SELECT * FROM products WHERE current_stock < minimum_order_quantity` |
| `calculate_stock_trends` | Analyze sales velocity | `SELECT AVG(daily_sales) FROM sales_history WHERE product_id = %s AND date > NOW() - INTERVAL '30 days'` |
| `generate_reorder_alert` | Create alert message | Combines stock data with trend analysis |
| `log_inventory_check` | Record check in audit_log | `INSERT INTO audit_log (agent_id, action, ...)` |

### Validation Rules
- Alerts must include the exact SQL query used for verification.
- CAO validates by running the same query independently.
- All alerts are logged with timestamp, product ID, and calculated metrics.

### Strategy Pattern Implementation
- **Query Strategy:** `InventoryStrategy`
  - Uses complex `JOIN` queries to link `products`, `stock_levels`, and `order_history`.
  - Uses aggregation (`AVG`, `SUM`) for trend analysis.
  - Optimized for read-heavy workloads.

### Error Handling
- **Missing Data:** "Could not calculate stock trends for Product X due to missing sales history."
- **System Error:** "Failed to connect to the database. Retrying in 5 minutes."
- **Threshold Error:** "Minimum order quantity not set for Product X. Skipping alert."

---

*This agent will be built following the blueprint pattern, adapted for scheduled/cron execution rather than real-time chat.*
