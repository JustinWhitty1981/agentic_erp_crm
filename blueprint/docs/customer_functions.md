# Customer Functions Reference

**Purpose:** SQL functions for customer management operations.

**Location:** `scripts/database/09_customer_functions.sql`

---

## Overview

Customer functions provide a clean API for managing entities, contacts, and their relationships. All functions are stored in the PostgreSQL catalog and can be called directly from Python tools.

---

## Customer Lookup Functions

### `get_customer_by_id(entity_id)`

Retrieve complete customer information by entity ID.

```sql
SELECT * FROM get_customer_by_id(123);
```

**Returns:**
- entity_id, entity_type, name, legal_name, industry, website, status
- Primary contact information (first_name, last_name, email, phone, title)
- Primary address (street, city, state, postal_code, country)
- Total communication count
- Last communication date

**Example:**
```python
result = cursor.execute("""
    SELECT * FROM get_customer_by_id(%s),
    (123,)
).fetchone()
```

### `search_customers_by_name(search_term)`

Search customers by name using full-text search.

```sql
SELECT * FROM search_customers_by_name('bob');
```

**Returns:** Matching entities with primary contact and communication stats.

### `search_customers_by_email(email)`

Find customer by email address.

```sql
SELECT * FROM search_customers_by_email('john@example.com');
```

### `search_customers_by_phone(phone)`

Find customer by phone number.

```sql
SELECT * FROM search_customers_by_phone('555-1234');
```

---

## Customer Management Functions

### `create_customer(name, entity_type, email, phone, ...)`

Create a new customer entity with optional contact and address.

```sql
SELECT create_customer(
    name => 'Acme Corporation',
    entity_type => 'customer',
    email => 'contact@acme.com',
    phone => '555-1234',
    industry => 'Manufacturing'
);
```

**Returns:** New entity ID.

**Parameters:**
- `name` (TEXT, required): Entity name
- `entity_type` (VARCHAR, default 'customer'): Type of entity
- `email` (TEXT, optional): Primary contact email
- `phone` (TEXT, optional): Primary contact phone
- `legal_name` (TEXT, optional): Legal business name
- `industry` (TEXT, optional): Industry classification
- `website` (TEXT, optional): Website URL
- `first_name` (TEXT, optional): Primary contact first name
- `last_name` (TEXT, optional): Primary contact last name
- `title` (TEXT, optional): Primary contact title
- `street` (TEXT, optional): Street address
- `city` (TEXT, optional): City
- `state` (TEXT, optional): State
- `postal_code` (TEXT, optional): Postal code
- `country` (TEXT, optional): Country (default 'US')

### `update_customer(entity_id, ...)`

Update customer information with audit logging.

```sql
SELECT update_customer(
    entity_id => 123,
    name => 'Acme Corp Updated',
    industry => 'Technology'
);
```

**Parameters:** All parameters are optional. Only provided fields are updated.

**Audit:** Updates are logged to `audit_log` table with old and new values.

### `delete_customer(entity_id)`

Soft delete a customer (sets status to 'inactive').

```sql
SELECT delete_customer(123);
```

**Note:** Does not physically delete records to preserve audit trail.

---

## Contact Management Functions

### `add_contact_to_entity(entity_id, first_name, last_name, ...)`

Add a contact to an existing entity.

```sql
SELECT add_contact_to_entity(
    entity_id => 123,
    first_name => 'Jane',
    last_name => 'Smith',
    email => 'jane@acme.com',
    title => 'Procurement Manager',
    is_primary => true
);
```

**Returns:** New contact ID.

### `update_contact(contact_id, ...)`

Update contact information.

```sql
SELECT update_contact(
    contact_id => 456,
    email => 'jane.smith@acme.com',
    title => 'Senior Procurement Manager'
);
```

### `set_primary_contact(entity_id, contact_id)`

Set a contact as the primary contact for an entity.

```sql
SELECT set_primary_contact(123, 456);
```

---

## Communication Functions

### `log_communication(entity_id, communication_type, summary, ...)`

Log a communication with an entity.

```sql
SELECT log_communication(
    entity_id => 123,
    communication_type => 'email',
    direction => 'inbound',
    subject => 'Product Inquiry',
    summary => 'Customer asked about pricing for bulk orders',
    outcome => 'resolved',
    sentiment_score => 0.8
);
```

**Returns:** Communication ID.

**Parameters:**
- `entity_id` (INTEGER, required): Entity to log communication for
- `communication_type` (VARCHAR, required): Type of communication
- `direction` (VARCHAR, optional): 'inbound', 'outbound', 'internal'
- `subject` (TEXT, optional): Subject line
- `summary` (TEXT, required): AI-generated summary
- `full_content` (TEXT, optional): Full transcript
- `outcome` (VARCHAR, optional): 'resolved', 'escalated', 'pending', 'closed'
- `sentiment_score` (FLOAT, optional): Sentiment score (-1 to 1)
- `follow_up_required` (BOOLEAN, optional): Requires follow-up?
- `follow_up_date` (DATE, optional): Follow-up date

### `get_communications(entity_id, days)`

Retrieve communications for an entity.

```sql
SELECT * FROM get_communications(123, 30);
```

**Returns:** Communications from the last N days.

### `get_communication_thread(communication_id)`

Get complete conversation thread.

```sql
SELECT * FROM get_communication_thread(789);
```

---

## Utility Functions

### `split_name(full_name)`

Parse a full name into first and last name.

```sql
SELECT split_name('John Doe');
-- Returns: ('John', 'Doe')
```

### `get_entity_relationships(entity_id)`

Get all contacts and their roles for an entity.

```sql
SELECT * FROM get_entity_relationships(123);
```

### `get_customer_statistics(entity_id)`

Get aggregated statistics for a customer.

```sql
SELECT * FROM get_customer_statistics(123);
```

**Returns:**
- Total communications
- Resolved count
- Escalated count
- Average sentiment
- Last contact date
- Open follow-ups count

---

## Best Practices

1. **Always use functions** - Don't directly INSERT/UPDATE tables for customer operations
2. **Audit logging** - All changes are automatically logged
3. **Soft deletes** - Use `delete_customer()` instead of direct DELETE
4. **Vector embeddings** - Automatically generated for semantic search
5. **Transaction safety** - Functions run in transactions for data integrity

---

## Error Handling

Functions raise descriptive errors:

- `NOT_FOUND`: Entity or contact not found
- `DUPLICATE_EMAIL`: Email already exists
- `INVALID_TYPE`: Invalid entity_type or communication_type
- `REQUIRED_FIELD`: Missing required field

---

*Generated for Agent First ERP CRM - Customer management function reference*