"""
Entity Stats Tool - Get communication statistics for customers/entities.
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
def get_entity_stats(entity_name: str) -> str:
    """Get communication statistics for a customer/entity.
    Use this when the user asks about total communications, resolved issues, or engagement metrics.
    """
    conn = get_db_connection()
    if isinstance(conn, str):
        return conn
    
    try:
        with conn.cursor() as cur:
            query = """
                SELECT entity_name, entity_type, status, total_communications, resolved_count, pending_count
                FROM agent_swarm.entity_communication_stats
                WHERE entity_name ILIKE %s
                LIMIT 5
            """
            cur.execute(query, (f"%{entity_name}%",))
            rows = cur.fetchall()
            
            if rows:
                results = []
                for row in rows:
                    name, etype, status, total, resolved, pending = row
                    results.append(f"{name} ({status}): {total} total communications, {resolved} resolved, {pending} pending")
                return "Entity statistics:\n" + "\n".join(results)
            else:
                return f"No statistics found for '{entity_name}'."
    except Exception as e:
        return f"Error retrieving statistics: {e}"
    finally:
        conn.close()