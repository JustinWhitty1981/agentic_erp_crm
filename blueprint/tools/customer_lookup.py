"""
Customer Lookup Tool - Retrieve customer information by name.
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
def get_customer_info(customer_name: str) -> str:
    """Look up customer information by name.
    Use this when the user asks about a customer, their contact info, or status.
    """
    conn = get_db_connection()
    if isinstance(conn, str):
        return conn
    
    try:
        with conn.cursor() as cur:
            query = "SELECT name, email, phone, address, status FROM agent_first_erp_crm.vw_customers WHERE name ILIKE %s LIMIT 5"
            cur.execute(query, (f"%{customer_name}%",))
            rows = cur.fetchall()
            
            if rows:
                results = []
                for row in rows:
                    name, email, phone, address, status = row
                    results.append(f"{name} ({status}): {email}, {phone}\n   Address: {address}")
                return "Found customers:\n" + "\n\n".join(results)
            else:
                return f"No customers found matching '{customer_name}'."
    except Exception as e:
        return f"Error looking up customer: {e}"
    finally:
        conn.close()