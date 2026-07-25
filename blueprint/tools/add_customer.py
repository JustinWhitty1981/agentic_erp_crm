"""
Add Customer Tool - Add new customers (individuals or businesses) to the database.
"""

import re
from datetime import datetime
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
def add_customer_tool(
    first_name: Optional[str] = None,
    last_name: Optional[str] = None,
    email: Optional[str] = None,
    phone: Optional[str] = None,
    street: Optional[str] = None,
    city: Optional[str] = None,
    state: Optional[str] = None,
    postal_code: Optional[str] = None,
    country: str = "US",
    customer_type: str = "individual",
    organization_name: Optional[str] = None,
    address_type: str = "home",
    is_primary: bool = True
) -> str:
    """Add a new customer (individual or business) to the database.
    
    For individual customers:
    - first_name: Customer's first name (required for individuals)
    - last_name: Customer's last name (required for individuals)
    
    For business customers:
    - organization_name: Business name (required for businesses)
    - first_name/last_name: Optional contact person for the business
    
    At least one of:
    - email: Email address
    - phone: Phone number
    
    Optional fields:
    - street: Street address
    - city: City
    - state: State/Province
    - postal_code: ZIP/Postal code
    - country: Country code (default: US)
    - customer_type: "individual" or "business" (default: "individual")
    - address_type: "home", "billing", "shipping", or "office" (default: "home")
    - is_primary: Whether this is the primary address (default: True)
    
    Returns a confirmation message with the customer ID.
    """
    # Normalize inputs
    first_name = first_name.strip() if first_name else None
    last_name = last_name.strip() if last_name else None
    email = normalize_email(email) if email else None
    phone = normalize_phone(phone) if phone else None
    organization_name = organization_name.strip() if organization_name else None
    
    # Validation based on customer type
    if customer_type == "individual":
        if not first_name:
            return "Error: First name is required for individual customers."
        if not last_name:
            return "Error: Last name is required for individual customers."
    elif customer_type == "business":
        if not organization_name:
            return "Error: Organization name is required for business customers."
    else:
        return "Error: customer_type must be 'individual' or 'business'."
    
    if not email and not phone:
        return "Error: At least one of email or phone is required."
    
    conn = get_db_connection()
    if isinstance(conn, str):
        return conn
    
    try:
        with conn.cursor() as cur:
            # Call the add_customer function with all new parameters
            query = """
                SELECT * FROM agent_first_erp_crm.add_customer(
                    %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
                )
            """
            cur.execute(query, (
                first_name, last_name, email, phone,
                street, city, state, postal_code, country, 'active',
                customer_type, organization_name, address_type, is_primary
            ))
            
            result = cur.fetchone()
            success, entity_id, contact_id, message = result
            
            if success:
                # Log the creation to communications
                cur.execute("""
                    INSERT INTO agent_first_erp_crm.communications 
                    (entity_id, contact_id, communication_type, direction, summary, created_at)
                    VALUES (%s, %s, %s, %s, %s, %s)
                """, (
                    entity_id, contact_id, 'system', 'outbound',
                    f'Customer record created: {first_name} {last_name}',
                    datetime.now()
                ))
            
            conn.commit()
            return message if success else f"Failed to add customer: {message}"
    
    except Exception as e:
        if hasattr(conn, 'rollback'):
            conn.rollback()
        return f"Error adding customer: {e}"
    
    finally:
        conn.close()