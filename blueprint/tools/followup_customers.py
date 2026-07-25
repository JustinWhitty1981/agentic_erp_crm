"""
Follow-up Customers Tool - Get list of customers requiring follow-up.
"""

import psycopg2
from dotenv import load_dotenv
from langchain_core.tools import tool
import os

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
def get_followup_customers_tool(days_threshold: int = 7) -> str:
    """Get a list of customers who require follow-up.
    
    Customers are flagged for follow-up if:
    - Their status is marked as 'follow-up'
    - They haven't had any communications in the specified number of days (default: 7)
    - Their last communication has an unresolved outcome (pending/escalated)
    
    Returns a formatted list of customers with their contact information and follow-up reason.
    """
    conn = get_db_connection()
    if isinstance(conn, str):
        return conn
    
    try:
        with conn.cursor() as cur:
            query = """
                SELECT entity_id, name, email, phone, last_communication_date, follow_up_reason
                FROM agent_first_erp_crm.get_followup_customers(%s)
                ORDER BY last_communication_date ASC NULLS LAST
            """
            cur.execute(query, (days_threshold,))
            rows = cur.fetchall()
            
            if not rows:
                return "No customers currently require follow-up."
            
            result_lines = [f"Customers requiring follow-up ({len(rows)} found):", ""]
            
            for row in rows:
                entity_id, name, email, phone, last_comm, reason = row
                last_comm_str = last_comm.strftime('%Y-%m-%d %H:%M') if last_comm else 'Never'
                
                result_lines.append(f"• {name}")
                if email:
                    result_lines.append(f"  - Email: {email}")
                if phone:
                    result_lines.append(f"  - Phone: {phone}")
                result_lines.append(f"  - Last contact: {last_comm_str}")
                result_lines.append(f"  - Reason: {reason}")
                result_lines.append("")
            
            return "\n".join(result_lines)
    
    except Exception as e:
        return f"Error retrieving follow-up customers: {e}"
    
    finally:
        conn.close()