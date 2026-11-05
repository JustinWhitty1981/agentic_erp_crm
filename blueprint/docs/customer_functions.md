# Customer Functions - the doors, as they exist

> **What changed on this page.** It used to reference a function library that was never in this
> database: `get_customer_by_id`, `search_customers_by_name`, `search_customers_by_email`,
> `search_customers_by_phone`, `create_customer`, `delete_customer`, `log_communication`,
> `get_communications`, `get_communication_thread`, `get_entity_relationships`,
> `get_customer_statistics`, `add_contact_to_entity`, `update_contact`, `set_primary_contact`. Measured
> against `pg_proc`, **every one of those answers zero rows** - they are the shape the July design
> assumed, and `db/migrations/` built something smaller and stricter instead. What the schema really
> offers is below: four customer doors, one read function, three memory doors, and views for every
> read that does not need a parameter.
>
> The rule that decides which half a capability lands in is ADR-002 and ADR-003: **a read is a `vw_*`
> view, a write is a function, and a parameterised read is a function too.** A tool that composed its
> own `INSERT` would put the business rule where the database cannot enforce it, which is finding 4.5
> and the reason `code:cs_writes_through_doors` exists.

## The customer doors

### `add_customer` - create a customer

15 parameters, every one `DEFAULT`ed (0016's shape: one head, no overloads, so a call cannot resolve to
a definition nobody intended). Returns `TABLE(success, entity_id, contact_id, message)`.

```sql
SELECT * FROM add_customer(
  p_first_name := 'Grace', p_last_name := 'Okafor',
  p_email := 'grace@okafor.example', p_phone := '+15125550111',
  p_street := '18 Cedar Ct', p_city := 'Austin', p_state := 'TX',
  p_postal_code := '78704', p_country := 'US',
  p_entity_type := 'individual', p_status := 'active',
  p_idempotency_key := gen_random_uuid());
```

It writes four tables in one transaction - `entities`, `contacts`, `entity_relationships`, and
`addresses` when an address was given - and refuses a name or email that already exists (`ILIKE`, so
`Grace Okafor` cannot be added twice, which is why the acceptance harness stamps its fixtures).
For a business, pass `p_organization_name` (that becomes the entity name) plus the contact person's
name; `p_is_primary` decides whose number the read paths reach through.

There is **no `delete_customer`**, and the closest thing to one is the referential rule 0008 left in
place: `communications.entity_id` and `.contact_id` are `NO ACTION`, so an entity with a history cannot
be dropped out from under it (0008's own note counts the CASCADE edges it *did* remove, against business
data, and what it converted to RESTRICT is the stock and reservation keys). Soft delete is planned for
`0025`. Until it lands, a customer is retired by `p_status`, not removed.

And read `p_entity_type` honestly, because it is the clearest live example of T2: the parameter decides
only **how the name is assembled** - `business` takes `p_organization_name`, anything else concatenates
first and last. The `INSERT` writes the literal `'customer'` into `entities.entity_type` either way.
`vendor` and `prospect` are values the column's CHECK admits and no function ever stores, which is why
`vw_customers` cannot filter on them and why the marker `code:vw_customers_filter` has no `closed()`
branch: the decision has not been made, and a page that said otherwise would be describing a column
nobody writes.

### `update_customer` - change an existing customer's fields

13 parameters; identification is by **search** fields, and an omitted value keeps what is stored.

```sql
SELECT * FROM update_customer(
  p_search_name := 'Grace Okafor', p_search_email := 'grace@okafor.example',
  p_street := '19 Cedar Ct');
```

`p_search_*` select and never change anything, and a selection that reaches two rows is refused rather
than applied to whichever the scan hit first - the same rule `add_communication` has and for the same
reason. `vw_customers` carries the row it changed. Note two facts about this door that the register
publishes: it is **UNGUARDED** in `vw_idempotency_status` (it sets values, so a retry lands the same
state - ADR-005's pattern-1 reasoning rather than a claim), and `p_status` cannot make a customer a
`prospect`, because `prospect` is an `entity_type` value and no function in the schema writes
`entity_type` after creation. That open question is `code:vw_customers_filter` / **T2**, and probe
`4_5` prints it as KNOWN-OPEN rather than pretending it passes.

### `add_communication` - log one interaction

The only door that writes `communications` (20 parameters, all `DEFAULT`ed, 0021).

```sql
SELECT * FROM add_communication(
  p_customer_name := 'Grace Okafor',
  p_communication_type := 'call', p_direction := 'inbound',
  p_subject := 'Shipping timeline', p_summary := 'Discussed ORD-10001 shipping.',
  p_channel := 'phone', p_sentiment_label := 'neutral', p_outcome := 'pending',
  p_follow_up_required := true, p_follow_up_date := CURRENT_DATE + 3,
  p_idempotency_key := gen_random_uuid());
```

Four behaviours a caller-side `INSERT` could not have promised, all of them in the migration's prose:
a name matching more than one row is **refused with the candidates listed**; an id that row security
hides answers as a refusal instead of a NULL a foreign key would accept; the six vocabularies are the
column CHECKs' own, so `p_direction := 'sideways'` keeps its `23514`; and `thread_root_id` inherits the
parent's root, so a reply to a reply lands on the thread the first message started. A
`p_follow_up_required` without a date is refused - the flag and the date are one decision. It creates
**no `followups` row**: that table has no writer anywhere in the schema, and 0021 §5 says so rather
than deciding it.

### `mark_customer_followup` - set or clear the follow-up mark

```sql
SELECT * FROM mark_customer_followup(p_entity_id := 11, p_followup := true);
```

Writes `entities.status` (`'follow-up'` / `'active'`), which is what `get_followup_customers`' first
branch reads. Unguarded by claim, for the same reason `update_customer` is.

## The parameterised read

### `get_followup_customers(p_days_threshold integer DEFAULT 7)`

Returns `TABLE(entity_id, name, email, phone, last_communication_date, follow_up_reason)` for the
customers who need contact, with the reason named: `No recent communications`, `Status marked for
follow-up`, or `Unresolved communication`, checked in that order. A negative or NULL threshold is
`22023` before any scan (0022), and the staleness clock is the *interaction*, not the row's write time -
which is the difference 0022 found, and why `db/seeds/01_demo_customers.sql` with its backdated history
is what makes the probe discriminating.

It is a function rather than a view because it takes an argument, and it joins through each customer's
**primary** contact, so an account without one appears nowhere.

## Memory (ADR-002's half that is not a customer table)

```sql
SELECT * FROM save_memory(p_key := 'grace.pref', p_content := 'prefers email',
                          p_idempotency_key := gen_random_uuid());
SELECT * FROM get_memory(p_key := 'grace.pref', p_limit := 10);
SELECT * FROM list_memories();
```

`agent_memories` is append-only by grant (B28 asserts it), keyed per tenant, and it is what both agents
read after a restart instead of a container directory.

## Reading, which is views and not functions

| Need | Read |
|---|---|
| A customer by id, name, email or phone | `vw_customers` (`WHERE` is yours; the columns are `id, name, email, phone, address, status, created_at, updated_at, tenant_id`) |
| One customer's interaction history | `vw_customer_communications_summary` |
| The last seven days | `vw_recent_communications` |
| Per-customer counts, sentiment, first/last contact | `vw_entity_communication_stats` |
| A thread, flattened | `vw_communication_thread` |
| Who is due a call | `get_followup_customers(days)` - the one above |

The old names on this page were `get_customer_by_id` and `get_communications`; both are a `SELECT` now,
and ADR-003 is why they are not functions.

## Applying them

Nothing here is applied by hand. The definitions are in `db/migrations/0001` (ported), `0016`
(one `add_customer` head), `0017` (the interaction read path), `0021` (`add_communication`), `0022`
(`get_followup_customers`) and `0023` (memory), and `scripts/db/db up` applies them in filename order.
`blueprint/09_add_update_customer_functions.sql` and `scripts/database/09_customer_functions.sql` are
the superseded copies of the first two - kept so the fork is legible, and both qualified to a schema no
migration creates, so running either writes somewhere the views cannot see.
