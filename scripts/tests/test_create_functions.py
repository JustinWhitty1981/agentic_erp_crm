import os
from dotenv import load_dotenv
load_dotenv()
#!/usr/bin/env python3
"""
Test creating functions one at a time.
"""

import psycopg2

DB_CONFIG = {
    "host": os.getenv("POSTGRES_HOST", "localhost"),
    "port": int(os.getenv("POSTGRES_PORT", "5432")),
    "database": os.getenv("POSTGRES_DB", "agent_first_erp_crm"),
    "user": os.getenv("POSTGRES_USER", "postgres"),
    "password": os.getenv("POSTGRES_PASSWORD", ""),
}

# Test add_customer function creation
add_customer_sql = """
DROP FUNCTION IF EXISTS add_customer(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);
CREATE FUNCTION add_customer(
    p_first_name TEXT,
    p_last_name TEXT,
    p_email TEXT,
    p_phone TEXT,
    p_street TEXT DEFAULT NULL,
    p_city TEXT DEFAULT NULL,
    p_state TEXT DEFAULT NULL,
    p_postal_code TEXT DEFAULT NULL,
    p_country TEXT DEFAULT 'US',
    p_status TEXT DEFAULT 'active'
) RETURNS TABLE(success BOOLEAN, entity_id INTEGER, contact_id INTEGER, message TEXT) AS $$
BEGIN
    RETURN QUERY SELECT TRUE, 1::INTEGER, 1::INTEGER, 'Test';
END;
$$ LANGUAGE plpgsql;
"""

conn = psycopg2.connect(**DB_CONFIG)
try:
    with conn.cursor() as cur:
        cur.execute(add_customer_sql)
    conn.commit()
    print("✓ add_customer function created successfully")
except Exception as e:
    print(f"✗ Error creating add_customer: {e}")
finally:
    conn.close()
