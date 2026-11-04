#!/usr/bin/env python3
"""Regenerate the **Columns:** lists in blueprint/docs/views.md from pg_attribute.

Why a script and not a hand edit: 17 of the page's 17 lists disagree with the catalog, and the ways
they disagree are the interesting part - invented names (`bot_id` on a view whose column is
agent_id), columns that 0009 added to every tenant view and the page never took back (tenant_id, in
all twelve), and columns a later migration added to a view the page still describes as it was in
0001. Fixing that by hand is 60 edits with a coin flip on each.

Descriptions are kept from the page wherever it already named the column. A column the page never
listed gets one only from the dictionary below, which is limited to names whose meaning is a fact of
the schema rather than a guess - and a bare `name` is what any other new column gets, because an
invented sentence about a column nobody documented is how the page ended up wrong in the first place.
"""
import re
import subprocess
import sys
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PAGE = os.path.join(ROOT, "blueprint", "docs", "views.md")
NOTE = ("**Columns:** (the list, in declared order, from `pg_attribute`; `0019`'s documentation sweep "
        "regenerated every one on this page, and `code:agent_docs_match_surface` re-checks them)")

DESC = {
    "tenant_id": "Whose row this is. Every tenant-coded view exposes it last (0009), which is what "
                 "makes an agent's and an auditor's result sets differ without two views",
    "agent_id": "Which agent recorded the row; `agent_interactions.bot_id` is the same idea on the "
                "trajectory side, and this view groups by `agent_id` because that is the column "
                "`communications` has",
    "id": "The view's own key, carried from the underlying row",
    "interaction_id": "The `agent_interactions` primary key",
    "run_id": "One agent run's identifier - the value `idempotency_keys` scopes a retry by (ADR-005)",
    "conversation_id": "Threads the runs of one conversation together",
    "step_number": "Position within the run's `actions_taken`, which is how the two jsonb arrays stay "
                   "aligned with each other",
    "timestamp": "When the run happened; quoted everywhere it appears, because `timestamp` is reserved",
    "name": "The entity's or item's own name column",
    "entity_id": "The `entities` row this is about",
    "contact_id": "The `contacts` row this is about, or NULL when no person was named",
    "item_id": "The `inventory_items` row this is about",
    "warehouse_id": "The `warehouses` row this is about",
    "category_id": "The `item_categories` row this is about",
    "location_id": "The `locations` row this is about",
    "sku": "The item's stock-keeping unit",
    "status": "The row's status, from that table's own vocabulary - `vw_domain_vocabulary` lists it",
    "outcome": "How the interaction ended, from the CHECKed list in `vw_domain_vocabulary`",
    "direction": "inbound, outbound or internal",
    "communication_type": "call, chat, email, meeting, note, sms, telegram or ticket",
    "subject": "The line a human would recognise as what it was about",
    "summary": "What happened, in the space the schema budgets for it",
    "started_at": "When the interaction began - the column the staleness clocks read (0022)",
    "created_at": "When the row was written, which is not the same fact and 0022 is the finding that "
                  "says so",
    "updated_at": "When the row last changed, if the table keeps one - `vw_timestamp_status` says "
                  "which do",
    "entity_name": "The customer's name, resolved by the view rather than by the caller",
    "entity_type": "customer or prospect; the CHECK is the list",
    "contact_name": "The person's name, from `contacts`",
    "contact_title": "The person's title, from `contacts`",
    "channel": "How the interaction arrived, where the table distinguishes it from the type",
    "priority": "How soon this matters, from the column's own vocabulary",
    "sentiment_label": "positive, neutral or negative - the label, not a score",
    "sentiment_score": "The numeric sentiment, where one was recorded",
    "follow_up_required": "Whether someone owes this customer a contact",
    "follow_up_date": "When that contact is due; `vw_pending_followups` is the other half",
    "thread_root_id": "The first message of the thread this reply belongs to",
    "parent_id": "The message this one answers",
    "duration_seconds": "How long the interaction took, in seconds",
    "duration_ms": "How long the run took, in milliseconds",
    "model_used": "Which model answered",
    "error_message": "Why the run failed, or NULL",
    "human_input": "What the caller actually said",
    "final_output": "What the agent finally said back",
    "actions_taken": "One entry per tool call, in order",
    "tool_observations": "One entry per tool call, in the same order - the pairing `vw_tool_calls` "
                         "depends on",
    "observations_aligned": "Whether that pairing held for this run, stated rather than assumed",
    "response_sources": "Which records the answer was built from",
    "intent_classification": "The intent the router picked, if it names one",
    "confidence_score": "How sure the router claimed to be",
    "step_count": "How many tool calls the run made, so a scan need not expand the payload",
    "telegram_chat_id": "The Telegram chat the run came from",
    "user_id": "Who the caller is, in the transport's terms",
    "currency_code": "What the numbers on this row are in. Nothing converts (0018)",
    "total_value": "Units times cost, summed within the group and no further",
    "available_value": "The value of what could actually be shipped",
    "quantity_available": "On hand minus reserved, which is the number a promise can be made against",
    "quantity_on_hand": "What the count says is there",
    "quantity_reserved": "What is committed and still on the shelf",
    "quantity_in_transit": "Expected, not arrived",
    "total_units": "How many of this item, across the group",
    "total_inbound": "Receipts in the window, reservations excluded - a commitment makes stock "
                     "unavailable, it moves nothing (0019's note)",
    "total_outbound": "Issues in the window, reservations excluded, for the same reason",
    "net_quantity": "What the stock level moved by, reservations included",
    "movement_count": "How many ledger rows the window holds",
    "movement_date": "The day the movements happened",
    "movement_type": "RECEIPT, ISSUE, TRANSFER, ADJUSTMENT, RETURN or RESERVATION",
    "reorder_point": "Below this, the item is on the list",
    "safety_stock": "The buffer the reorder arithmetic keeps",
    "lead_time_days": "How long a replenishment takes, per supplier",
    "average_cost": "The item's cost as this balance carries it, in `cost_currency`",
    "cost_currency": "Which currency `average_cost` is in",
    "needs_reorder": "Whether the level is at or below the reorder point",
    "stock_status": "In stock, low, out, or over - the alert's word for the comparison",
    "alert_level": "The same comparison, named for the alert rather than for the shelf",
    "stock_percentage": "How far the level is from full, as a number the UI can bar",
    "total_available": "Available across every row the group covers",
    "shortage_amount": "How far below the reorder point, if below",
    "unique_items": "How many distinct items the group holds",
    "unique_entities": "How many customers the agent has touched",
    "unique_contacts": "How many people, which is not the same count",
    "total_communications": "How many interactions the customer has",
    "total_actions": "How many rows the agent produced",
    "resolved_count": "Interactions that ended resolved",
    "pending_count": "Interactions still pending",
    "escalated_count": "Interactions escalated to someone",
    "negative_count": "Interactions labelled negative",
    "positive_count": "Interactions labelled positive",
    "avg_sentiment": "The mean of the sentiment that was labelled",
    "avg_duration_seconds": "Mean interaction length",
    "avg_unit_cost": "Mean cost per unit over the window",
    "first_contact_date": "The oldest interaction",
    "last_contact_date": "The newest interaction",
    "first_activity": "The earliest row this agent wrote",
    "last_activity": "The latest row this agent wrote",
    "call_count": "How many times the tool was called, counted per call",
    "run_count": "In how many runs it was called, which is the denominator the timing means use",
    "errored_run_count": "How many of those runs failed, not how many calls did - the base table "
                         "records one error per run",
    "errored_run_pct": "The ratio of the two, as a percentage",
    "mean_run_duration_ms": "Mean duration over the runs that used the tool",
    "tool_name": "Which tool the row is about",
    "due_date": "When the follow-up is owed",
    "due_date": "When the follow-up is owed",
    "description": "What is owed",
    "completed_at": "When it was done",
    "completion_notes": "Notes left at completion",
    "is_active": "Whether the master row is still in use, in place of deleting it",
    "is_primary": "Whether this is the primary one of several",
    "is_lot_controlled": "Whether the item is tracked by lot",
    "is_serialized": "Whether the item is tracked by serial number",
    "expiry_date": "When a tracked lot stops being good",
    "base_unit_of_measure": "What the quantity means, from `units_of_measure`",
    "warehouse_name": "The warehouse's name",
    "warehouse_code": "The warehouse's code",
    "warehouse_type": "What the warehouse is for",
    "location_code": "The bin's code",
    "category_name": "The category's name",
    "entity_status": "The customer's own status",
    "from_currency": "The currency the pair is quoted from",
    "to_currency": "And to",
    "rate_in_force": "The number to multiply by, or NULL when no row is in force",
    "in_force": "Whether a row covers the instant the view was asked at",
    "rows_for_pair": "How many rows the pair has ever had, so *expired* and *never quoted* read "
                     "differently",
    "as_of": "The instant the view measured at - a `now()` in a view answers a different question on "
             "every scan, so it is named",
    "valid_from": "When this row's authority starts",
    "valid_to": "And ends; NULL means still in force",
    "source": "Where the quote came from",
    "primary_contact": "The contact marked primary for the entity",
    "communication_type": "call, chat, email, meeting, note, sms, telegram or ticket",
    "human_agent_id": "The person who handled it, when a person did",
    "entity_type": "customer or prospect; the CHECK is the list",
    "thread_root_id": "The first message of the thread this reply belongs to",
}


def catalog():
    out = subprocess.run(
        ["docker", "exec", "afpc-pg", "psql", "-U", "postgres", "-d", "agent_first_erp_crm", "-tAc",
         "SELECT c.relname || ' ' || a.attname || ' ' || a.attnum "
         "FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid "
         "JOIN pg_namespace n ON n.oid = c.relnamespace "
         "WHERE n.nspname = 'public' AND c.relkind = 'v' AND a.attnum > 0 AND NOT a.attisdropped"],
        capture_output=True, text=True, check=True).stdout
    views = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 3:
            continue
        views.setdefault(parts[0], []).append((int(parts[2]), parts[1]))
    for v in views:
        views[v] = [name for _, name in sorted(views[v])]
    return views


def main():
    views = catalog()
    src = open(PAGE, encoding="utf-8").read()
    lines = src.split("\n")
    out, i, changed, kept, added = [], 0, 0, 0, 0
    current = None
    while i < len(lines):
        line = lines[i]
        m = re.match(r"^### (vw_[a-z0-9_]+)\s*$", line)
        if m:
            current = m.group(1)
        if line.startswith("**Columns:") and current in views:
            # Read the block that follows, keeping each column's description.
            block, j = {}, i + 1
            while j < len(lines) and re.match(r"^- `", lines[j]):
                mm = re.match(r"^- `([a-z_]+)`(?:\s*-\s*(.*))?$", lines[j])
                if mm:
                    block[mm.group(1)] = (mm.group(2) or "").strip()
                j += 1
            new = [NOTE]
            for col in views[current]:
                desc = block.get(col) or DESC.get(col)
                if block.get(col):
                    kept += 1
                elif col not in block:
                    added += 1
                new.append("- `%s`%s" % (col, " - " + desc if desc else ""))
            out.extend(new)
            out.extend(lines[j:j + (0 if j >= len(lines) or lines[j].strip() == "" else 1)])
            if j < len(lines) and lines[j].strip() != "":
                out.append("")
            i = j + (1 if j < len(lines) and lines[j].strip() == "" else 0)
            changed += 1
            continue
        out.append(line)
        i += 1
    open(PAGE, "w", encoding="utf-8").write("\n".join(out))
    print(f"{changed} lists rewritten, {kept} descriptions kept, {added} columns added")


if __name__ == "__main__":
    sys.exit(main())
