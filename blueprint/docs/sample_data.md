# Sample Data Setup

**Purpose:** SQL scripts for populating the database with sample data for testing and development.

**Location:** `scripts/database/setup_sample_data.sql`

---

## Overview

This document provides sample data for testing the Agent Swarm system. The data includes:

- Sample customers (entities)
- Sample contacts
- Entity relationships
- Sample communications
- Sample inventory items and warehouses

---

## Sample Customers

### Customer 1: Acme Corporation

```sql
INSERT INTO agent_swarm.entities (entity_type, name, industry, website, status)
VALUES ('customer', 'Acme Corporation', 'Manufacturing', 'https://acme-corp.com', 'active');

-- Primary contact
INSERT INTO agent_swarm.contacts (first_name, last_name, email, phone, title, status)
VALUES ('John', 'Smith', 'john.smith@acme.com', '555-1234', 'Procurement Manager', 'active')
RETURNING id;

-- Link contact to entity
INSERT INTO agent_swarm.entity_relationships (entity_id, contact_id, role, is_primary)
VALUES (1, 1, 'Procurement Manager', true);

-- Primary address
INSERT INTO agent_swarm.addresses (entity_id, address_type, street, city, state, postal_code, country, is_primary)
VALUES (1, 'headquarters', '123 Industrial Way', 'Chicago', 'IL', '60601', 'US', true);
```

### Customer 2: TechStart Inc

```sql
INSERT INTO agent_swarm.entities (entity_type, name, industry, website, status)
VALUES ('customer', 'TechStart Inc', 'Technology', 'https://techstart.io', 'active');

INSERT INTO agent_swarm.contacts (first_name, last_name, email, phone, title, status)
VALUES ('Sarah', 'Johnson', 'sarah@techstart.io', '555-5678', 'CTO', 'active')
RETURNING id;

INSERT INTO agent_swarm.entity_relationships (entity_id, contact_id, role, is_primary)
VALUES (2, 2, 'Chief Technology Officer', true);

INSERT INTO agent_swarm.addresses (entity_id, address_type, street, city, state, postal_code, country, is_primary)
VALUES (2, 'headquarters', '456 Innovation Drive', 'San Francisco', 'CA', '94105', 'US', true);
```

### Customer 3: Global Retail Partners

```sql
INSERT INTO agent_swarm.entities (entity_type, name, industry, status)
VALUES ('customer', 'Global Retail Partners', 'Retail', 'active');

INSERT INTO agent_swarm.contacts (first_name, last_name, email, phone, title, status)
VALUES ('Michael', 'Chen', 'm.chen@globalretail.com', '555-9012', 'VP Operations', 'active')
RETURNING id;

INSERT INTO agent_swarm.entity_relationships (entity_id, contact_id, role, is_primary)
VALUES (3, 3, 'VP Operations', true);
```

---

## Sample Communications

```sql
-- Communication 1: Email inquiry
INSERT INTO agent_swarm.communications (
    entity_id, contact_id, communication_type, direction, subject, summary,
    outcome, sentiment_score, sentiment_label, follow_up_required
) VALUES (
    1, 1, 'email', 'inbound', 'Product Pricing Inquiry',
    'John inquired about bulk pricing for Widget A. Provided quote for 1000+ units.',
    'resolved', 0.8, 'positive', false
);

-- Communication 2: Support ticket
INSERT INTO agent_swarm.communications (
    entity_id, contact_id, communication_type, direction, subject, summary,
    outcome, sentiment_score, sentiment_label, follow_up_required, priority
) VALUES (
    2, 2, 'ticket', 'inbound', 'Integration Issue',
    'Sarah reported API integration failing with 500 errors. Engineering team investigating.',
    'pending', -0.3, 'negative', true, 'high'
);

-- Communication 3: Follow-up call
INSERT INTO agent_swarm.communications (
    entity_id, contact_id, communication_type, direction, subject, summary,
    outcome, sentiment_score, sentiment_label
) VALUES (
    1, 1, 'call', 'outbound', 'Quarterly Review Call',
    'Scheduled quarterly business review. Customer satisfied with service.',
    'resolved', 0.6, 'positive'
);
```

---

## Sample Inventory Data

### Item Categories

```sql
INSERT INTO agent_swarm.item_categories (category_code, name) VALUES
('RAW', 'Raw Materials'),
('FIN', 'Finished Goods'),
('ACC', 'Accessories');

INSERT INTO agent_swarm.item_categories (category_code, name, parent_category_id)
SELECT 'SUB', 'Subcomponents', id FROM agent_swarm.item_categories WHERE category_code = 'RAW';
```

### Warehouses

```sql
INSERT INTO agent_swarm.warehouses (warehouse_code, name, is_active) VALUES
('WH-MAIN', 'Main Warehouse - Chicago', true),
('WH-WEST', 'West Coast Warehouse - LA', true),
('WH-EAST', 'East Coast Warehouse - Newark', true);
```

### Locations

```sql
INSERT INTO agent_swarm.locations (warehouse_id, location_code, zone, aisle, bin)
SELECT w.warehouse_id, 'A-01-01', 'A', '01', '01'
FROM agent_swarm.warehouses w WHERE w.warehouse_code = 'WH-MAIN';
```

### Inventory Items

```sql
INSERT INTO agent_swarm.inventory_items (sku, name, category_id, base_unit_of_measure, standard_cost, safety_stock, reorder_point, is_active)
SELECT 'WIDGET-A', 'Widget Type A', c.category_id, 'EACH', 10.50, 100, 200, true
FROM agent_swarm.item_categories c WHERE c.category_code = 'FIN';

INSERT INTO agent_swarm.inventory_items (sku, name, category_id, base_unit_of_measure, standard_cost, safety_stock, reorder_point, is_active)
SELECT 'WIDGET-B', 'Widget Type B', c.category_id, 'EACH', 15.75, 50, 100, true
FROM agent_swarm.item_categories c WHERE c.category_code = 'FIN';

INSERT INTO agent_swarm.inventory_items (sku, name, category_id, base_unit_of_measure, standard_cost, safety_stock, reorder_point, is_active)
SELECT 'RAW-STEEL', 'Steel Sheet 1mm', c.category_id, 'SQFT', 2.50, 500, 1000, true
FROM agent_swarm.item_categories c WHERE c.category_code = 'RAW';
```

### Inventory On Hand

```sql
INSERT INTO agent_swarm.inventory_on_hand (item_id, warehouse_id, quantity_on_hand, quantity_available, quantity_reserved)
SELECT i.item_id, w.warehouse_id, 500, 450, 50
FROM agent_swarm.inventory_items i, agent_swarm.warehouses w
WHERE i.sku = 'WIDGET-A' AND w.warehouse_code = 'WH-MAIN';
```

---

## Sample Vendors

```sql
INSERT INTO agent_swarm.entities (entity_type, name, industry, status)
VALUES ('vendor', 'Steel Supply Co', 'Manufacturing', 'active');

INSERT INTO agent_swarm.contacts (first_name, last_name, email, phone, title, status)
VALUES ('Robert', 'Williams', 'r.williams@steelsupply.com', '555-3456', 'Sales Director', 'active')
RETURNING id;

INSERT INTO agent_swarm.entity_relationships (entity_id, contact_id, role, is_primary)
VALUES (4, 4, 'Sales Director', true);
```

---

## Running the Sample Data Script

```bash
# Execute the sample data script
psql -h {your-host} -U {your-username} -d {your-database-name} -f scripts/database/setup_sample_data.sql
```

---

## Verification Queries

```sql
-- Check entities
SELECT entity_type, COUNT(*) FROM agent_swarm.entities GROUP BY entity_type;

-- Check communications
SELECT communication_type, COUNT(*) FROM agent_swarm.communications GROUP BY communication_type;

-- Check inventory
SELECT i.sku, i.name, ioh.quantity_on_hand, w.name as warehouse
FROM agent_swarm.inventory_items i
JOIN agent_swarm.inventory_on_hand ioh ON i.item_id = ioh.item_id
JOIN agent_swarm.warehouses w ON ioh.warehouse_id = w.warehouse_id;
```

---

*Generated for Agent Swarm - Sample data setup documentation*