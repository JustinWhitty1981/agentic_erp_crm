#!/usr/bin/env python3
"""
Setup customer management functions step by step.
"""

import os
import psycopg2

DB_CONFIG = {
    "host": os.getenv("POSTGRES_HOST", "localhost"),
    "port": int(os.getenv("POSTGRES_PORT", "5432")),
    "database": os.getenv("POSTGRES_DB", "agent_first_erp_crm"),
    "user": os.getenv("POSTGRES_USER", "postgres"),
    "password": os.getenv("POSTGRES_PASSWORD", ""),
}

# Drop existing functions
drop_sql = """
DROP FUNCTION IF EXISTS add_customer(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS update_customer(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS get_followup_customers(INTEGER);
"""

# Read the full SQL file
from pathlib import Path
sql_file = Path(__file__).parent / "09_add_update_customer_functions.sql"
full_sql = sql_file.read_text()

# Remove the DROP statements since we already ran them
# and remove the GRANT statements for now
create_only = "\n".join([
    line for line in full_sql.split('\n')
    if not line.strip().startswith('DROP FUNCTION')
    and not line.strip().startswith('GRANT EXECUTE')
])

conn = psycopg2.connect(**DB_CONFIG)
try:
    # First drop
    with conn.cursor() as cur:
        cur.execute(drop_sql)
    print("✓ Dropped existing functions")
    
    # Then create
    with conn.cursor() as cur:
        cur.execute(create_only)
    conn.commit()
    print("✓ Created customer management functions")
    
    # Verify
    with conn.cursor() as cur:
        cur.execute("""
            SELECT routine_name 
            FROM information_schema.routines 
            WHERE routine_schema = 'agent_first_erp_crm' 
            AND routine_name IN ('add_customer', 'update_customer', 'get_followup_customers')
            ORDER BY routine_name;
        """)
        functions = cur.fetchall()
        print(f"Created functions: {[f[0] for f in functions]}")
        
except Exception as e:
    print(f"Error: {e}")
    conn.rollback()
    raise
finally:
    conn.close()
