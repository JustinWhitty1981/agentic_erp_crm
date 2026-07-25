import os
from dotenv import load_dotenv
load_dotenv()
#!/usr/bin/env python3
"""
Test creating update_customer function.
"""

import psycopg2

DB_CONFIG = {
    "host": os.getenv("POSTGRES_HOST", "localhost"),
    "port": int(os.getenv("POSTGRES_PORT", "5432")),
    "database": os.getenv("POSTGRES_DB", "agent_swarm"),
    "user": os.getenv("POSTGRES_USER", "postgres"),
    "password": os.getenv("POSTGRES_PASSWORD", ""),
}

# Test update_customer function creation (simplified version)
update_customer_sql = """
DROP FUNCTION IF EXISTS update_customer(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);
CREATE FUNCTION update_customer(
    p_search_name TEXT,
    p_search_email TEXT DEFAULT NULL,
    p_search_phone TEXT DEFAULT NULL,
    p_first_name TEXT DEFAULT NULL,
    p_last_name TEXT DEFAULT NULL,
    p_email TEXT DEFAULT NULL,
    p_phone TEXT DEFAULT NULL,
    p_street TEXT DEFAULT NULL,
    p_city TEXT DEFAULT NULL,
    p_state TEXT DEFAULT NULL,
    p_postal_code TEXT DEFAULT NULL,
    p_country TEXT DEFAULT NULL,
    p_status TEXT DEFAULT NULL
) RETURNS TABLE(success BOOLEAN, entity_id INTEGER, contact_id INTEGER, message TEXT) AS $$
BEGIN
    RETURN QUERY SELECT TRUE, 1::INTEGER, 1::INTEGER, 'Test update';
END;
$$ LANGUAGE plpgsql;
"""

conn = psycopg2.connect(**DB_CONFIG)
try:
    with conn.cursor() as cur:
        cur.execute(update_customer_sql)
    conn.commit()
    print("✓ update_customer function created successfully")
except Exception as e:
    print(f"✗ Error creating update_customer: {e}")
finally:
    conn.close()
