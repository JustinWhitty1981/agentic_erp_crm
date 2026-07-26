# Enterprise Relationship Graph

**Purpose:** Visualize and document all relationships between tables in the Agent First ERP CRM database.  
**Design Philosophy:** Enterprise-grade, mirroring SAP, Oracle, and Salesforce architectures.  
**Status:** Complete - Entity-Contact-Communication Model

---

## 🗺️ High-Level Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           AGENT FIRST ERP CRM DATABASE                              │
│                                                                             │
│  ┌─────────────┐      ┌──────────────┐      ┌──────────────────┐          │
│  │  ENTITIES   │◄─────┤ RELATIONSHIPS│─────►│     CONTACTS     │          │
│  │ (Companies/ │      │  (Who works  │      │   (People)       │          │
│  │ Individuals)│      │   Where)     │      │                  │          │
│  └──────┬──────┘      └──────────────┘      └─────────┬────────┘          │
│         │                                             │                    │
│         │                                             │                    │
│         ▼                                             ▼                    │
│  ┌─────────────┐                              ┌──────────────────┐        │
│  │ ADDRESSES   │                              │ COMMUNICATIONS   │        │
│  │ (Locations) │                              │ (Interactions)   │        │
│  └─────────────┘                              └──────────────────┘        │
│                                                                             │
│  ┌────────────────────────────────────────────────────────────────────┐    │
│  │                    AUDIT TRAIL (Human-Bot Interactions)           │    │
│  │  ┌──────────────┐              ┌──────────────┐                   │    │
│  │  │ HUMAN_SESSIONS│────────────►│ BOT_ACTIONS  │                   │    │
│  │  └──────────────┘              └──────────────┘                   │    │
│  └────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 📊 Detailed Table Relationships

### 1. **Entities Table** (Core Business Partner)

**Purpose:** Stores business organizations OR individuals that transact with us.

| Relationship | Related Table | Cardinality | Description |
|-------------|---------------|-------------|-------------|
| **HAS_MANY** | `contacts` | 1:N | An entity can have multiple contacts |
| **HAS_MANY** | `addresses` | 1:N | An entity can have multiple addresses (billing, shipping, HQ) |
| **HAS_MANY** | `communications` | 1:N | An entity can have many communications |
| **HAS_MANY** | `entity_relationships` | 1:N | Links contacts to this entity with roles |
| **REFERRED_BY** | `human_sessions` | N:1 | Human sessions reference an entity |
| **REFERRED_BY** | `bot_actions` | N:1 | Bot actions reference an entity |

**Key Fields:**
- `id` (PK): Unique entity identifier
- `entity_type`: 'customer', 'vendor', 'prospect', 'employee'
- `name`: Display name (company or individual)
- `legal_name`: Legal business name (NULL for individuals)
- `status`: 'active', 'inactive', 'blacklisted'

---

### 2. **Contacts Table** (People)

**Purpose:** Stores individual human beings.

| Relationship | Related Table | Cardinality | Description |
|-------------|---------------|-------------|-------------|
| **HAS_MANY** | `entity_relationships` | 1:N | A contact can work for multiple entities |
| **HAS_MANY** | `addresses` | 1:N | A contact can have multiple addresses |
| **HAS_MANY** | `communications` | 1:N | A contact can have many communications |
| **REFERRED_BY** | `human_sessions` | N:1 | Human sessions reference a contact |
| **REFERRED_BY** | `bot_actions` | N:1 | Bot actions reference a contact |

**Key Fields:**
- `id` (PK): Unique contact identifier
- `first_name`, `last_name`: Person's name
- `email`, `phone`: Contact information
- `title`: Job title (e.g., "CFO", "Owner")

---

### 3. **Entity_Relationships Table** (The Link)

**Purpose:** Defines how contacts relate to entities.

| Relationship | Related Table | Cardinality | Description |
|-------------|---------------|-------------|-------------|
| **LINKS_TO** | `entities` | N:1 | Links to the entity |
| **LINKS_TO** | `contacts` | N:1 | Links to the contact |

**Key Fields:**
- `entity_id` (FK): References `entities.id`
- `contact_id` (FK): References `contacts.id`
- `role`: Contact's role at the entity (e.g., "Procurement Manager")
- `is_primary`: Is this the primary contact?
- `start_date`, `end_date`: Temporal relationship tracking

**Unique Constraint:** One primary contact per entity (`is_primary = TRUE`)

---

### 4. **Addresses Table** (Locations)

**Purpose:** Stores addresses for entities and/or contacts.

| Relationship | Related Table | Cardinality | Description |
|-------------|---------------|-------------|-------------|
| **BELONGS_TO** | `entities` | N:1 | Address belongs to an entity |
| **BELONGS_TO** | `contacts` | N:1 | Address belongs to a contact (optional) |

**Key Fields:**
- `entity_id` (FK): References `entities.id` (optional)
- `contact_id` (FK): References `contacts.id` (optional)
- `address_type`: 'billing', 'shipping', 'headquarters', 'mailing'
- `street`, `city`, `state`, `postal_code`, `country`
- `is_primary`: Is this the primary address?

**Design Note:** Can reference either entity OR contact, or both.

---

### 5. **Communications Table** (Interactions)

**Purpose:** Records all interactions with entities/contacts.

| Relationship | Related Table | Cardinality | Description |
|-------------|---------------|-------------|-------------|
| **BELONGS_TO** | `entities` | N:1 | Communication belongs to an entity |
| **BELONGS_TO** | `contacts` | N:1 | Communication involves a contact (optional) |
| **LINKED_TO** | `communications` (self) | N:1 | Parent-child threading |
| **HANDLED_BY** | `contacts` (human_agent) | N:1 | Human agent who handled it |
| **HANDLED_BY** | `agents` (future) | N:1 | Bot that handled it |

**Key Fields:**
- `entity_id` (FK): References `entities.id` (REQUIRED)
- `contact_id` (FK): References `contacts.id` (optional)
- `communication_type`: 'email', 'call', 'meeting', 'ticket', 'chat', 'note'
- `direction`: 'inbound', 'outbound', 'internal'
- `summary`: AI-generated summary (REQUIRED)
- `full_content`: Full transcript (optional)
- `attachments`: JSONB array of file references (NOT BLOBs)
- `parent_id` (FK): Self-reference for threading
- `thread_root_id`: Root of the conversation thread
- `sentiment_score`, `sentiment_label`: AI sentiment (placeholders)
- `outcome`: 'resolved', 'escalated', 'pending', 'closed'
- `follow_up_required`, `follow_up_date`: Task management
- `embedding`: Vector for semantic search

**Design Pattern:** Parent-child threading with `thread_root_id` for easy retrieval of entire conversations.

---

### 6. **Human_Sessions Table** (Audit Trail)

**Purpose:** Tracks when humans log in and start sessions with agents.

| Relationship | Related Table | Cardinality | Description |
|-------------|---------------|-------------|-------------|
| **LINKS_TO** | `contacts` | N:1 | Human user who logged in |
| **LINKS_TO** | `entities` | N:1 | Entity context for the session |
| **HAS_MANY** | `bot_actions` | 1:N | Actions performed during the session |

**Key Fields:**
- `user_id`: Human user identifier
- `user_name`: Display name
- `contact_id` (FK): Links to `contacts.id` (if known)
- `entity_id` (FK): Links to `entities.id` (if applicable)
- `bot_id`: Bot being commanded
- `bot_type`: Type of bot (e.g., 'customer_service')
- `login_time`, `logout_time`: Session timestamps
- `session_status`: 'active', 'completed', 'terminated'

---

### 7. **Bot_Actions Table** (Audit Trail)

**Purpose:** Logs every action taken by a bot.

| Relationship | Related Table | Cardinality | Description |
|-------------|---------------|-------------|-------------|
| **BELONGS_TO** | `human_sessions` | N:1 | Session during which action occurred |
| **LINKS_TO** | `contacts` | N:1 | Human user who commanded the bot |
| **LINKS_TO** | `entities` | N:1 | Entity context for the action |
| **LINKS_TO** | `communications` | N:1 | Optional link to related communication |

**Key Fields:**
- `session_id` (FK): References `human_sessions.id`
- `user_id`: Human user identifier
- `contact_id` (FK): Links to `contacts.id` (if known)
- `entity_id` (FK): Links to `entities.id` (if applicable)
- `bot_id`: Bot that performed the action
- `action_type`: Type of action (e.g., 'query', 'update', 'export')
- `action_description`: Human-readable description
- `input_parameters`, `output_result`: JSONB data
- `success`: Boolean
- `error_message`: Error if failed
- `execution_time_ms`: Performance metric
- `timestamp`: When the action occurred

---

## 🔗 Relationship Patterns

### Pattern 1: Entity-Contact-Communication Triangle

```
┌─────────────┐
│   ENTITY    │─────┐
│ (Company)   │     │
└──────┬──────┘     │
       │            ▼
       │      ┌─────────────┐
       │      │COMMUNICATION│
       │      │ (Interaction)│
       │      └──────┬──────┘
       ▼             │
┌─────────────┐     │
│  CONTACT    │─────┘
│  (Person)   │
└─────────────┘
```

**Usage:** "Find all communications between Bob's Small Engines (Entity) and Jane Smith (Contact)"

### Pattern 2: Threading with Parent-Child

```
Communication #1 (Root)
  └── Communication #2 (Parent: #1)
        └── Communication #3 (Parent: #2, Root: #1)
              └── Communication #4 (Parent: #3, Root: #1)
```

**Usage:** "Show me the entire email thread about Order #12345"

### Pattern 3: Multi-Entity Contact

```
┌─────────────┐
│  CONTACT    │
│  Jane Smith │
└──────┬──────┘
       │
       ├──► Entity #105: Bob's Small Engines (Role: Procurement Manager)
       │
       └──► Entity #203: Acme Corp (Role: Sales Director)
```

**Usage:** "Jane Smith works at multiple companies - show me her role at each"

### Pattern 4: Audit Trail with Full Context

```
Human Session
  ├── Contact: Kimmy Sue
  ├── Entity: Bob's Small Engines
  ├── Bot: cs_bot_01
  └── Actions:
        ├── Query customer info
        ├── Create communication
        └── Update order status
```

**Usage:** "Who did what, when, and which bot was involved?"

---

## 📈 Query Patterns

### 1. Get Primary Contact for an Entity
```sql
SELECT c.first_name, c.last_name, c.email, c.phone
FROM agent_first_erp_crm.entity_relationships er
JOIN agent_first_erp_crm.contacts c ON c.id = er.contact_id
WHERE er.entity_id = 123 AND er.is_primary = TRUE;
```

### 2. Get All Communications for an Entity (Last 30 Days)
```sql
SELECT c.started_at, c.communication_type, c.subject, c.summary
FROM agent_first_erp_crm.communications c
WHERE c.entity_id = 123
  AND c.started_at >= NOW() - INTERVAL '30 days'
ORDER BY c.started_at DESC;
```

### 3. Get Complete Conversation Thread
```sql
SELECT * FROM agent_first_erp_crm.communications
WHERE thread_root_id = 456
ORDER BY started_at ASC;
```

### 4. Find All Contacts at an Entity
```sql
SELECT c.first_name, c.last_name, c.title, er.role
FROM agent_first_erp_crm.entity_relationships er
JOIN agent_first_erp_crm.contacts c ON c.id = er.contact_id
WHERE er.entity_id = 123;
```

### 5. Get Entity Details with Primary Contact
```sql
SELECT 
    e.name, e.entity_type, e.status,
    c.first_name || ' ' || c.last_name as primary_contact,
    c.email, c.phone
FROM agent_first_erp_crm.entities e
JOIN agent_first_erp_crm.entity_relationships er ON er.entity_id = e.id AND er.is_primary = TRUE
JOIN agent_first_erp_crm.contacts c ON c.id = er.contact_id
WHERE e.id = 123;
```

---

## 🎯 Design Principles

1. **Separation of Concerns**
   - Entities = Organizations/Individuals
   - Contacts = People
   - Relationships = How they connect
   - Communications = Interactions

2. **Flexibility**
   - One contact can work for multiple entities
   - One entity can have multiple contacts
   - Addresses can belong to entities OR contacts
   - Communications can involve entity, contact, or both

3. **Audit Trail**
   - Every action is logged with full context
   - Links to human sessions, contacts, entities, and bots
   - Immutable history for compliance

4. **Scalability**
   - `BIGSERIAL` for high-volume tables (communications, bot_actions)
   - `SERIAL` for moderate-volume tables (entities, contacts)
   - Indexed for performance
   - PGVector for semantic search

5. **Enterprise Alignment**
   - Mirrors SAP, Oracle, Salesforce patterns
   - Supports complex organizational structures
   - Temporal tracking (start_date, end_date)
   - Role-based access control ready

---

## 🚀 Future Extensions

### Planned Tables (Not Yet Implemented)

1. **`orders`** - Purchase orders linked to entities
2. **`order_items`** - Line items within orders
3. **`products`** - Product catalog
4. **`tickets`** - Support tickets (may merge with communications)
5. **`agents`** - Registry of all bots with permissions
6. **`audit_log`** - Immutable log of all system changes (**Not yet created**)

### Future Enhancements

- **Sentiment Analysis:** Integrate ML models for automatic sentiment scoring
- **Automated Summarization:** AI-generated summaries for long communications
- **Predictive Insights:** Churn risk, upsell opportunities based on communication patterns
- **Integration Hooks:** Webhooks for external CRM/ERP systems

---

## 📝 Maintenance Notes

- **Indexes:** All foreign keys and frequently queried columns are indexed
- **Triggers:** Auto-update `updated_at` timestamps
- **Constraints:** Foreign key constraints ensure referential integrity
- **Backups:** Communications and audit tables should be backed up separately (compliance)
- **Archival:** Old communications can be archived to cold storage after N years

---

*Last Updated: July 11, 2026*  
*Version: 2.0 (Enterprise Edition)*  
*Author: Jarvis (Agent First Team)*
