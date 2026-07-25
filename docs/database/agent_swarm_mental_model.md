# Agent Swarm Schema - Mental Model

## Core Business Domains

### 1. **Party Management** (Entities + Contacts)
- **Entities**: Companies / Organizations / Customers
- **Contacts**: People (employees, customer contacts)
- **Addresses**: Physical locations
- **Entity Relationships**: Links contacts to entities (with roles)

**Key Insight**: One Entity can have multiple Contacts. One Contact can relate to multiple Entities.

### 2. **Communication & Activity Layer**
- **Communications**: All interactions (calls, emails, chats, etc.)
- **Human Sessions**: When human agents log in with bot_id and bot_type
- **Bot Actions**: Every action taken by AI agents with full details
- **Audit Summary**: Daily aggregation of human-bot interactions
- **Agent Interactions**: Complete trajectory logging (thoughts, actions, observations)
- **Followups**: Action items / tasks

**Mental Model**: Communications are the **heart** of the system. Everything revolves around them. All agent actions are fully logged for debugging and auditing.

### 3. **Inventory & Supply Chain**
- **Item Categories** → **Inventory Items**
- **Warehouses** → **Locations**
- **Inventory On Hand** (current stock)
- **Inventory Movements** (all stock changes)
- **Reservations** (allocated stock)

**Key Flow**: Movement → Update On Hand → Reservation Management

---

## Key Relationships (Agent Mental Map)

```mermaid
graph TD
    Entity[Entity] -->|has| Contact[Contact]
    Entity -->|has| Address[Address]
    Communication[Communication] -->|belongs to| Entity
    Communication -->|with| Contact
    Communication -->|performed by| BotAction
    HumanSession[Human Session] -->|works on| Communication
    InventoryItem[Inventory Item] -->|stored in| Warehouse
    InventoryMovement -->|affects| InventoryOnHand
    Reservation -->|reserves| InventoryOnHand