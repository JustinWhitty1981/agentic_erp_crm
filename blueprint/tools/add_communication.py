"""
Add Communication Tool - Log a new customer communication to the database.
"""

import psycopg2
from datetime import datetime
from typing import Optional
from langchain_core.tools import tool
import os
from dotenv import load_dotenv

load_dotenv()

# Database configuration
DB_CONFIG = {
    "host": os.getenv("POSTGRES_HOST", "localhost"),
    "port": int(os.getenv("POSTGRES_PORT", 5432)),
    "database": os.getenv("POSTGRES_DB", "agent_swarm"),
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
    
    Args:
        customer_name: Name of the customer/entity
        direction: 'inbound' (customer contacted us) or 'outbound' (we contacted them)
        communication_type: 'call', 'email', 'meeting', 'chat', etc.
        summary: Brief summary of the interaction
        agent_name: Name of the staff member who handled the interaction (optional)
    
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
                "SELECT id FROM agent_swarm.customers WHERE name ILIKE %s LIMIT 1",
                (f"%{customer_name}%",)
            )
            entity_row = cur.fetchone()
            
            if not entity_row:
                return f"Could not find customer '{customer_name}' in the system."
            
            entity_id = entity_row[0]
            now = datetime.now()
            
            # Prepare the summary with agent name if provided
            final_summary = summary
            if agent_name:
                final_summary = f"Handled by {agent_name}. {summary}"
            
            # Insert into communications table
            cur.execute("""
                INSERT INTO agent_swarm.communications 
                (entity_id, communication_type, direction, summary, started_at)
                VALUES (%s, %s, %s, %s, %s)
                RETURNING id
            """, (entity_id, communication_type, direction, final_summary, now))
            
            comm_id = cur.fetchone()[0]
            conn.commit()
            
            return (
                f"✅ Communication logged successfully!\n"
                f"Customer: {customer_name}\n"
                f"Type: {direction.upper()} {communication_type}\n"
                f"Time: {now.strftime('%Y-%m-%d %H:%M')}\n"
                f"Summary: {final_summary}\n"
                f"ID: {comm_id}"
            )
    except Exception as e:
        conn.rollback()
        return f"Error logging communication: {e}"
    finally:
        conn.close()