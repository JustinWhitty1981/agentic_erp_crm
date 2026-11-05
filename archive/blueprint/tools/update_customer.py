"""
Update Customer Tool - Update existing customer information.
"""

import re
from typing import Optional
from langchain_core.tools import tool
import psycopg2
from dotenv import load_dotenv
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


def normalize_phone(phone: str) -> str:
    """Normalize phone number to E.164 format if possible."""
    if not phone:
        return phone
    
    # Remove all non-digit characters
    digits = re.sub(r'\D', '', phone)
    
    # Add country code if missing (assume US)
    if len(digits) == 10:
        digits = '1' + digits
    elif len(digits) == 11 and digits[0] == '1':
        pass  # Already has country code
    elif len(digits) == 11 and digits[0] != '1':
        digits = '1' + digits
    
    # Format as E.164
    if len(digits) == 11:
        return f"+{digits}"
    
    return phone


def normalize_email(email: str) -> str:
    """Normalize email to lowercase."""
    if not email:
        return email
    return email.strip().lower()


@tool
def update_customer_tool(
    search_name: str,
    search_email: Optional[str] = None,
    search_phone: Optional[str] = None,
    first_name: Optional[str] = None,
    last_name: Optional[str] = None,
    email: Optional[str] = None,
    phone: Optional[str] = None,
    street: Optional[str] = None,
    city: Optional[str] = None,
    state: Optional[str] = None,
    postal_code: Optional[str] = None,
    country: Optional[str] = None,
    status: Optional[str] = None
) -> str:
    """Update an existing customer's information.
    
    Required:
    - search_name: Name of the customer to find (partial match OK)
    
    Optional search criteria (helps find the right customer):
    - search_email: Email to help identify the customer
    - search_phone: Phone to help identify the customer
    
    Fields to update (only provide the ones you want to change):
    - first_name: New first name
    - last_name: New last name
    - email: New email address
    - phone: New phone number
    - street: New street address
    - city: New city
    - state: New state
    - postal_code: New postal code
    - country: New country
    - status: New status (e.g., 'active', 'inactive', 'follow-up')
    
    Returns a confirmation message with the updated information.
    """
    search_name = search_name.strip()
    email = normalize_email(email) if email else None
    phone = normalize_phone(phone) if phone else None
    search_email = normalize_email(search_email) if search_email else None
    
    if not search_name:
        return "Error: Customer name is required to search."
    
    conn = get_db_connection()
    if isinstance(conn, str):
        return conn
    
    try:
        with conn.cursor() as cur:
            # Call the update_customer function
            query = """
                SELECT * FROM update_customer(
                    %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
                )
            """
            cur.execute(query, (
                search_name, search_email, search_phone,
                first_name, last_name, email, phone,
                street, city, state, postal_code, country, status
            ))
            
            result = cur.fetchone()
            success, entity_id, contact_id, message = result

            # See add_customer.py for why no `communications` row is written here. The shorter
            # version: 'system' is not in that column's CHECK list, so the INSERT this replaces
            # raised 23514 and the rollback undid the update it was meant to describe, and the
            # change is in audit_log anyway - one row per row-change, with the actor, which is what
            # a field edit is. `communications` is for contact with a customer.

            conn.commit()
            return message if success else f"Failed to update customer: {message}"
    
    except Exception as e:
        if hasattr(conn, 'rollback'):
            conn.rollback()
        return f"Error updating customer: {e}"
    
    finally:
        conn.close()