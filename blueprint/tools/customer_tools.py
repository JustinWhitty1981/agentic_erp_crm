"""
Customer Management Tools for the Customer Service Bot.
Provides tools for adding and updating customers with validation.
"""

import re
from datetime import datetime
from typing import Optional
from langchain_core.tools import tool
import psycopg2
from dotenv import load_dotenv
import os

load_dotenv()

# Database configuration - use environment variables
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
                SELECT * FROM agent_swarm.add_customer(
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
                    INSERT INTO agent_swarm.communications 
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
                SELECT * FROM agent_swarm.update_customer(
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
            
            if success:
                # Log the update to communications
                cur.execute("""
                    INSERT INTO agent_swarm.communications 
                    (entity_id, contact_id, communication_type, direction, summary, created_at)
                    VALUES (%s, %s, %s, %s, %s, %s)
                """, (
                    entity_id, contact_id, 'system', 'outbound',
                    f'Customer information updated: {first_name or ""} {last_name or ""}',
                    datetime.now()
                ))
            
            conn.commit()
            return message if success else f"Failed to update customer: {message}"
    
    except Exception as e:
        if hasattr(conn, 'rollback'):
            conn.rollback()
        return f"Error updating customer: {e}"
    
    finally:
        conn.close()


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
                FROM agent_swarm.get_followup_customers(%s)
                ORDER BY last_communication_date ASC NULLS LAST
            """
            cur.execute(query, (days_threshold,))
            rows = cur.fetchall()
            
            if not rows:
                return "No customers currently require follow-up."
            
            result_lines = [f"*Customers requiring follow-up* ({len(rows)} found):", ""]
            
            for row in rows:
                entity_id, name, email, phone, last_comm, reason = row
                last_comm_str = last_comm.strftime('%Y-%m-%d %H:%M') if last_comm else 'Never'
                
                # Use Telegram-friendly formatting: bold names, bullet points, no tables
                result_lines.append(f"👤 *{name}*")
                if email:
                    result_lines.append(f"   • Email: {email}")
                if phone:
                    result_lines.append(f"   • Phone: {phone}")
                result_lines.append(f"   • Last contact: {last_comm_str}")
                result_lines.append(f"   • Reason: *{reason}*")
                result_lines.append("")  # Blank line between entries
            
            return "\n".join(result_lines)
    
    except Exception as e:
        return f"Error retrieving follow-up customers: {e}"
    
    finally:
        conn.close()


# Export tools list
CUSTOMER_TOOLS = [add_customer_tool, update_customer_tool, get_followup_customers_tool]
