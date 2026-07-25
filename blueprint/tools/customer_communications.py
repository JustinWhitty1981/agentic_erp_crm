"""
Customer Communications Tool - Retrieve customer communication history.
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
def get_customer_communications(customer_name: str) -> str:
    """Get recent communications for a customer.
    Use this when the user asks about communication history, recent contacts, or interaction summaries.
    """
    conn = get_db_connection()
    if isinstance(conn, str):
        return conn
    
    try:
        with conn.cursor() as cur:
            query = """
                SELECT started_at, entity_name, communication_type, direction, summary 
                FROM agent_first_erp_crm.vw_recent_communications 
                WHERE entity_name ILIKE %s 
                ORDER BY started_at DESC 
                LIMIT 5
            """
            cur.execute(query, (f"%{customer_name}%",))
            rows = cur.fetchall()
            
            if rows:
                results = []
                for row in rows:
                    date, name, comm_type, direction, summary = row
                    results.append(f"{date.strftime('%Y-%m-%d %H:%M')} - {direction.upper()} ({comm_type}): {summary}")
                return f"Recent communications for {customer_name}:\n" + "\n".join(results)
            else:
                return f"No communications found for '{customer_name}'."
    except Exception as e:
        return f"Error retrieving communications: {e}"
    finally:
        conn.close()