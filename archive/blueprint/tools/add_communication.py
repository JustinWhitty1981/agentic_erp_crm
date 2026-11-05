"""
Add Communication Tool - Log a new customer communication to the database.
"""

import psycopg2
from typing import Optional
from langchain_core.tools import tool
import os
from dotenv import load_dotenv

load_dotenv()

# Database configuration
DB_CONFIG = {
    "host": os.getenv("POSTGRES_HOST", "localhost"),
    "port": int(os.getenv("POSTGRES_PORT", 5432)),
    "database": os.getenv("POSTGRES_DB", "agent_first_erp_crm"),
    "user": os.getenv("POSTGRES_USER", "postgres"),
    "password": os.getenv("POSTGRES_PASSWORD", ""),
}


def get_db_connection():
    """Create a PostgreSQL connection."""
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        return conn
    except Exception as e:
        return f"Database connection error: {e}"


@tool
def add_communication(
    customer_name: str,
    direction: str,
    communication_type: str,
    summary: str,
    agent_name: Optional[str] = None
) -> str:
    """Log a new customer communication to the database.
    Use this after a real-world interaction (call, meeting, email) with a customer.

    The row is created by the `add_communication` SQL function, not by an INSERT here. That is the
    whole design of this tool and it is worth understanding before copying it: requirement 5 is
    "log new interactions", and a caller-side INSERT puts the rules for a `communications` row in
    whichever caller wrote it last, while the CHECK constraints, the tenant predicate and the
    idempotency claim stay in the database where a caller cannot edit them. An earlier revision of
    this file did carry its own INSERT, and it is finding 4.5 in docs/database/DATABASE_REVIEW.md -
    the review's example of a tool and a schema that disagree.

    Args:
        customer_name: Name of the customer/entity. An exact match wins; otherwise a unique
            case-insensitive substring is enough. Two customers sharing the substring is a refusal
            that lists the candidates, because `SELECT id ... WHERE name ILIKE '%x%' LIMIT 1` would
            otherwise file this interaction against whichever row the scan reached first.
        direction: 'inbound' (customer contacted us), 'outbound' (we contacted them), or 'internal'.
            Those three are the column's CHECK list; anything else is refused by the database.
        communication_type: One of 'call', 'chat', 'email', 'meeting', 'note', 'sms', 'telegram',
            'ticket'. Naming the list rather than saying "etc." is deliberate: a guessed sixth value
            costs a round trip to find out it is refused.
        summary: Brief summary of the interaction
        agent_name: Name of the staff member who handled the interaction (optional). It goes into
            the `agent_id` column, not into the summary text - which is what makes "who handled this"
            a query (`vw_agent_activity_summary`) instead of a search for the word "Handled".

    Returns:
        Confirmation message with the logged communication details, or the database's refusal.
    """
    conn = get_db_connection()
    if isinstance(conn, str):
        return conn

    try:
        with conn.cursor() as cur:
            # Every argument is named, so a future parameter added to the function cannot be
            # supplied positionally in the wrong slot by an unchanged caller.
            cur.execute(
                """SELECT success, communication_id, entity_id, message
                   FROM add_communication(
                       p_customer_name := %s,
                       p_communication_type := %s,
                       p_direction := %s,
                       p_summary := %s,
                       p_agent_id := %s)""",
                (customer_name, communication_type, direction, summary, agent_name),
            )
            row = cur.fetchone()
            conn.commit()

            success, comm_id, entity_id, message = row
            if not success:
                # The refusal is the database's sentence, and it already names the candidates or the
                # constraint. Reformatting it here would be a second copy of a rule with two owners.
                return f"⚠️  Communication not logged: {message}"

            return (
                f"✅ Communication logged successfully!\n"
                f"Customer: {customer_name}\n"
                f"Type: {direction.upper()} {communication_type}\n"
                f"Summary: {summary}\n"
                f"ID: {comm_id}\n"
                f"{message}"
            )
    except Exception as e:
        conn.rollback()
        return f"Error logging communication: {e}"
    finally:
        conn.close()