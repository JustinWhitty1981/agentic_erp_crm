"""
Communication Logger Tools

Example implementations for logging customer communications to the database.
These tools demonstrate patterns for recording interactions, tracking outcomes, and maintaining audit trails.
"""

import psycopg2
from datetime import datetime
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
            # First, get the entity_id from the customers view
            cur.execute(
                "SELECT id FROM agent_first_erp_crm.customers WHERE name ILIKE %s LIMIT 1",
                (f"%{customer_name}%",)
            )
            entity_row = cur.fetchone()
            
            if not entity_row:
                return f"Could not find customer '{customer_name}' in the system."
            
            entity_id = entity_row[0]
            
            # Get contact_id if available
            contact_id = None
            cur.execute("""
                SELECT c.id 
                FROM agent_first_erp_crm.contacts c
                JOIN agent_first_erp_crm.entity_relationships er ON c.id = er.contact_id
                WHERE er.entity_id = %s AND er.is_primary = TRUE
                LIMIT 1
            """, (entity_id,))
            contact_row = cur.fetchone()
            if contact_row:
                contact_id = contact_row[0]
            
            now = datetime.now()
            
            # Prepare the summary with agent name if provided
            final_summary = summary
            if agent_name:
                final_summary = f"Handled by {agent_name}. {summary}"
            
            # Insert into communications table
            cur.execute("""
                INSERT INTO agent_first_erp_crm.communications 
                (entity_id, contact_id, communication_type, direction, subject, summary, 
                 outcome, sentiment_label, follow_up_required, follow_up_date, created_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                RETURNING id
            """, (
                entity_id, contact_id, communication_type, direction, subject,
                final_summary, outcome, sentiment, follow_up_required, 
                follow_up_date, now
            ))
            
            comm_id = cur.fetchone()[0]
            conn.commit()
            
            response = (
                f"✅ Communication logged successfully!\n\n"
                f"📋 Details:\n"
                f"   Customer: {customer_name}\n"
                f"   Type: {direction.upper()} {communication_type}\n"
                f"   Time: {now.strftime('%Y-%m-%d %H:%M')}\n"
                f"   Summary: {final_summary}"
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
                query = """
                    SELECT id, started_at, communication_type, direction, subject, summary,
                           outcome, sentiment_label, follow_up_required, follow_up_date
                    FROM agent_first_erp_crm.communications c
                    JOIN agent_first_erp_crm.entities e ON c.entity_id = e.id
                    WHERE e.name ILIKE %s 
                    AND c.started_at >= NOW() - INTERVAL '%s days'
                    ORDER BY c.started_at DESC
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
            if due_date:
                query = """
                    SELECT c.id, e.name as entity_name, c.started_at, 
                           c.communication_type, c.summary, c.follow_up_date
                    FROM agent_first_erp_crm.communications c
                    JOIN agent_first_erp_crm.entities e ON c.entity_id = e.id
                    WHERE c.follow_up_required = TRUE
                    AND c.follow_up_date = %s
                    ORDER BY c.follow_up_date, c.started_at DESC
                """
                cur.execute(query, (due_date,))
            else:
                query = """
                    SELECT c.id, e.name as entity_name, c.started_at,
                           c.communication_type, c.summary, c.follow_up_date
                    FROM agent_first_erp_crm.communications c
                    JOIN agent_first_erp_crm.entities e ON c.entity_id = e.id
                    WHERE c.follow_up_required = TRUE
                    AND c.follow_up_date >= CURRENT_DATE
                    ORDER BY c.follow_up_date, c.started_at DESC
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