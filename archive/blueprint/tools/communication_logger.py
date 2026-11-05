"""
Communication Logger Tools

Patterns for recording interactions, tracking outcomes and reading them back. Two rules run through
this file, and both are here because the earlier revision broke them:

  - **A write goes through `add_communication` in SQL, never through an INSERT here.** The CHECK
    constraints, the tenant predicate and the idempotency claim live in the database; an INSERT in a
    tool restates some of them and silently skips the rest, which is finding 4.5. The visible symptom
    was a `WHERE name ILIKE %s LIMIT 1` that filed an interaction against whichever customer the scan
    reached first, with no error to report it.
  - **A read names a `vw_*` view.** The views are the published answer to "what may an agent ask
    about" (ADR-003); a hand-composed join to `entities` is a second copy of that decision, and it
    rots the day the view changes.

This module is also the reason the whole file was worth reading: until now it did not import. The
`query` assignment in get_communication_history was indented one level past its own block, so Python
raised IndentationError on import - and nothing caught it, because `bot.py` imports
`tools/add_communication.py` instead of this file. Documentation that happens to be executable has to
stay executable, or it is not documentation.
"""

import psycopg2
from typing import Optional
import os
from dotenv import load_dotenv

load_dotenv()

# Database configuration
DB_CONFIG = {
    "host": os.getenv("POSTGRES_HOST", "{your-postgres-host}"),
    "port": int(os.getenv("POSTGRES_PORT", 5432)),
    "database": os.getenv("POSTGRES_DB", "agent_first_erp_crm"),
    "user": os.getenv("POSTGRES_USER", "agent_first_erp_crm"),
    "password": os.getenv("POSTGRES_PASSWORD", "{yourpasswordhere}"),
}


def get_db_connection():
    """Create a PostgreSQL connection."""
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        return conn
    except Exception as e:
        return f"Database connection error: {e}"


def log_communication(
    customer_name: str,
    direction: str,
    communication_type: str,
    summary: str,
    subject: Optional[str] = None,
    outcome: Optional[str] = None,
    sentiment: Optional[str] = None,
    agent_name: Optional[str] = None,
    follow_up_required: bool = False,
    follow_up_date: Optional[str] = None
) -> str:
    """
    Log a new customer communication to the database.
    
    Args:
        customer_name: Name of the customer/entity
        direction: 'inbound' (customer contacted us) or 'outbound' (we contacted them)
        communication_type: 'call', 'email', 'meeting', 'chat', 'letter', etc.
        summary: Brief summary of the interaction
        subject: Optional subject line (for emails, etc.)
        outcome: Optional outcome (e.g., 'resolved', 'pending', 'escalated')
        sentiment: Optional sentiment ('positive', 'neutral', 'negative')
        agent_name: Name of the staff member who handled the interaction
        follow_up_required: Whether a follow-up is needed
        follow_up_date: Optional follow-up date (YYYY-MM-DD format)
    
    Returns:
        Confirmation message with the logged communication details
    """
    conn = get_db_connection()
    if isinstance(conn, str):
        return conn

    try:
        with conn.cursor() as cur:
            # The row is created by add_communication in SQL, not here. Finding 4.5 is this
            # function's earlier shape: it resolved the customer itself with
            # `WHERE name ILIKE %s LIMIT 1` and then INSERTed. That query keeps whichever row the scan
            # reaches first and discards the rest without an error, so two customers sharing a
            # substring meant filing a real interaction against the wrong one - and the trail then
            # recorded the mistake faithfully. The function refuses that case and lists the
            # candidates instead, which is not something a caller-side INSERT can do.
            #
            # No contact_id is passed, and this function used to fill one in by looking up the
            # entity's primary contact. That treats an `entities -> contacts` relationship as evidence
            # of a conversation, and it makes the row show up in vw_primary_contact_communications, a
            # view whose whole meaning is "interactions with this person". contact_id is what the
            # caller was told, or nothing.
            cur.execute(
                """SELECT success, communication_id, entity_id, message
                   FROM add_communication(
                       p_customer_name := %s,
                       p_communication_type := %s,
                       p_direction := %s,
                       p_subject := %s,
                       p_summary := %s,
                       p_outcome := %s,
                       p_sentiment_label := %s,
                       p_agent_id := %s,
                       p_follow_up_required := %s,
                       p_follow_up_date := %s)""",
                (customer_name, communication_type, direction, subject, summary,
                 outcome, sentiment, agent_name, follow_up_required, follow_up_date),
            )
            success, comm_id, entity_id, message = cur.fetchone()
            conn.commit()

            if not success:
                # The refusal is the database's sentence, and it already explains itself: the name was
                # ambiguous or unknown, the flag and the date disagreed, or a value is outside its
                # CHECK list. Re-wording it here would be a second copy of a rule with two owners.
                return f"⚠️  Communication not logged: {message}"

            response = (
                f"✅ Communication logged successfully!\n\n"
                f"📋 Details:\n"
                f"   Customer: {customer_name}\n"
                f"   Type: {direction.upper()} {communication_type}\n"
                f"   Summary: {summary}"
            )
            
            if subject:
                response += f"\n   Subject: {subject}"
            if outcome:
                response += f"\n   Outcome: {outcome}"
            if sentiment:
                response += f"\n   Sentiment: {sentiment}"
            if follow_up_required:
                response += f"\n   Follow-up: Required{f' (by {follow_up_date})' if follow_up_date else ''}"
            
            response += f"\n\nID: {comm_id}"
            
            return response
    
    except Exception as e:
        if hasattr(conn, 'rollback'):
            conn.rollback()
        return f"Error logging communication: {e}"
    
    finally:
        conn.close()


def log_call(
    customer_name: str,
    direction: str,
    summary: str,
    duration_minutes: Optional[int] = None,
    outcome: Optional[str] = None,
    agent_name: Optional[str] = None
) -> str:
    """
    Log a phone call communication.
    
    Args:
        customer_name: Name of the customer
        direction: 'inbound' or 'outbound'
        summary: Call summary
        duration_minutes: Call duration in minutes
        outcome: Call outcome
        agent_name: Handler name
    
    Returns:
        Confirmation message
    """
    extra_info = "call"
    if duration_minutes:
        extra_info = f"call ({duration_minutes} minutes)"
    
    return log_communication(
        customer_name=customer_name,
        direction=direction,
        communication_type=extra_info,
        summary=summary,
        outcome=outcome,
        agent_name=agent_name
    )


def log_email(
    customer_name: str,
    direction: str,
    subject: str,
    summary: str,
    outcome: Optional[str] = None,
    agent_name: Optional[str] = None
) -> str:
    """
    Log an email communication.
    
    Args:
        customer_name: Name of the customer
        direction: 'inbound' or 'outbound'
        subject: Email subject
        summary: Email content summary
        outcome: Email outcome
        agent_name: Handler name
    
    Returns:
        Confirmation message
    """
    return log_communication(
        customer_name=customer_name,
        direction=direction,
        communication_type="email",
        summary=summary,
        subject=subject,
        outcome=outcome,
        agent_name=agent_name
    )


def log_meeting(
    customer_name: str,
    meeting_type: str,
    summary: str,
    attendees: Optional[list] = None,
    outcome: Optional[str] = None,
    agent_name: Optional[str] = None
) -> str:
    """
    Log a meeting communication.
    
    Args:
        customer_name: Name of the customer
        meeting_type: Type of meeting (e.g., 'quarterly review', 'onboarding', 'support')
        summary: Meeting summary
        attendees: List of attendees
        outcome: Meeting outcome
        agent_name: Handler name
    
    Returns:
        Confirmation message
    """
    summary_text = summary
    if attendees:
        summary_text = f"Attendees: {', '.join(attendees)}. {summary}"
    
    return log_communication(
        customer_name=customer_name,
        direction="inbound",  # Meetings are typically inbound
        communication_type=f"meeting ({meeting_type})",
        summary=summary_text,
        outcome=outcome,
        agent_name=agent_name
    )


def get_communication_history(
    customer_name: str,
    days: int = 30,
    limit: int = 20
) -> str:
    """
    Get communication history for a customer.
    
    Args:
        customer_name: Name of the customer
        days: Number of days to look back (default: 30)
        limit: Maximum number of records to return (default: 20)
    
    Returns:
        Formatted communication history
    """
    conn = get_db_connection()
    if isinstance(conn, str):
        return conn

    try:
        with conn.cursor() as cur:
            # One view, one predicate, no join composed here. vw_customer_communications_summary
            # already resolves the entity name (ADR-003), and make_interval takes the day count as a
            # parameter instead of INTERVAL '%s days', which only works because psycopg2 substitutes
            # textually - a server-side prepared statement would reject it, and a reader cannot tell
            # from the source which driver a caller uses.
            query = """
                SELECT id, started_at, communication_type, direction, subject, summary,
                       outcome, sentiment_label, follow_up_required, follow_up_date
                FROM vw_customer_communications_summary
                WHERE entity_name ILIKE %s
                  AND started_at >= now() - make_interval(days => %s)
                ORDER BY started_at DESC
                LIMIT %s
            """
            cur.execute(query, (f"%{customer_name}%", days, limit))
            rows = cur.fetchall()
            
            if not rows:
                return f"No communications found for '{customer_name}' in the last {days} days."
            
            results = []
            for row in rows:
                result = f"📅 {row[1].strftime('%Y-%m-%d %H:%M')} - {row[3].upper()} ({row[2]})"
                if row[4]:
                    result += f"\n   Subject: {row[4]}"
                result += f"\n   Summary: {row[5]}"
                if row[6]:
                    result += f"\n   Outcome: {row[6]}"
                if row[7]:
                    result += f"\n   Sentiment: {row[7]}"
                if row[8]:
                    result += f"\n   Follow-up: Required{f' (by {row[9]})' if row[9] else ''}"
                results.append(result)
            
            return f"Communication history for {customer_name} ({len(rows)} found):\n\n" + "\n\n".join(results)
    
    except Exception as e:
        return f"Error retrieving communication history: {e}"
    
    finally:
        conn.close()


def get_follow_ups(due_date: Optional[str] = None, status: str = "pending") -> str:
    """
    Get communications requiring follow-up.
    
    Args:
        due_date: Filter by specific due date (YYYY-MM-DD format)
        status: Filter by status ('pending', 'completed')
    
    Returns:
        Formatted list of follow-ups
    """
    conn = get_db_connection()
    if isinstance(conn, str):
        return conn

    try:
        with conn.cursor() as cur:
            # `status` is the parameter this function declared and never read, which 0022 found in
            # get_followup_customers at the same time: a DEFAULTed argument no statement uses is a
            # dial that turns nothing. It filters on outcome now, using the same split 0022's
            # "Unresolved communication" branch uses - pending and escalated still need someone,
            # resolved and closed do not - so the two follow-up paths cannot disagree about what
            # "still open" means.
            #
            # The rows come from communications, not from vw_pending_followups. That view reads the
            # `followups` table, which has no writer anywhere in the schema (0021 §5 hands the decision
            # to whoever owns the task queue); following it here would make this function answer "no
            # follow-ups" forever, quietly.
            unresolved = """(outcome IS NULL OR outcome IN ('pending', 'escalated'))"""
            if status == "completed":
                where_status = "outcome IN ('resolved', 'closed')"
            elif status == "pending":
                where_status = unresolved
            else:
                return (f"status must be 'pending' or 'completed', not '{status}'. Those are the two "
                        f"readings of outcome the column's vocabulary supports; 'open' and 'done' are "
                        f"not members of it.")

            if due_date:
                query = f"""
                    SELECT id, entity_name, started_at, communication_type, summary, follow_up_date
                    FROM vw_customer_communications_summary
                    WHERE follow_up_required = TRUE
                      AND follow_up_date = %s
                      AND {where_status}
                    ORDER BY follow_up_date, started_at DESC
                """
                cur.execute(query, (due_date,))
            else:
                query = f"""
                    SELECT id, entity_name, started_at, communication_type, summary, follow_up_date
                    FROM vw_customer_communications_summary
                    WHERE follow_up_required = TRUE
                      AND follow_up_date >= CURRENT_DATE
                      AND {where_status}
                    ORDER BY follow_up_date, started_at DESC
                    LIMIT 50
                """
                cur.execute(query)
            
            rows = cur.fetchall()
            
            if not rows:
                return "No follow-ups found matching the criteria."
            
            results = []
            for row in rows:
                result = f"• {row[1]} - {row[3]}"
                result += f"\n   Original: {row[2].strftime('%Y-%m-%d %H:%M')}"
                result += f"\n   Summary: {row[4]}"
                if row[5]:
                    result += f"\n   Due: {row[5]}"
                results.append(result)
            
            return f"Follow-ups ({len(rows)} found):\n\n" + "\n\n".join(results)
    
    except Exception as e:
        return f"Error retrieving follow-ups: {e}"
    
    finally:
        conn.close()


# Example usage
if __name__ == "__main__":
    print("=== Communication Logger Tool Test ===\n")
    
    print("Test 1: Log a call")
    result = log_call(
        customer_name="Alice Johnson",
        direction="inbound",
        summary="Customer called to inquire about order status. Provided update on shipment.",
        duration_minutes=15,
        outcome="resolved",
        agent_name="John Smith"
    )
    print(result)
    print("\n" + "="*50 + "\n")
    
    print("Test 2: Log an email")
    result = log_email(
        customer_name="Bob's Small Engines",
        direction="outbound",
        subject="Follow-up on Service Request",
        summary="Sent follow-up email regarding completed service. Awaiting customer response.",
        outcome="pending",
        agent_name="Jane Doe"
    )
    print(result)
    print("\n" + "="*50 + "\n")
    
    print("Test 3: Get communication history")
    result = get_communication_history("Alice Johnson", days=30, limit=5)
    print(result)