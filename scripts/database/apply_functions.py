import os
from dotenv import load_dotenv
load_dotenv()
#!/usr/bin/env python3
"""
Apply the customer management functions to the database.
"""

import psycopg2
from pathlib import Path

# Database configuration
DB_CONFIG = {
    "host": os.getenv("POSTGRES_HOST", "localhost"),
    "port": int(os.getenv("POSTGRES_PORT", "5432")),
    "database": os.getenv("POSTGRES_DB", "agent_first_erp_crm"),
    "user": os.getenv("POSTGRES_USER", "postgres"),
    "password": os.getenv("POSTGRES_PASSWORD", ""),
}

def main():
    # Read the SQL file
    sql_file = Path(__file__).parent / "09_add_update_customer_functions.sql"
    sql_content = sql_file.read_text()
    
    # Split into statements (simple split by semicolon)
    statements = [s.strip() for s in sql_content.split(';') if s.strip()]
    
    # Connect to the database
    print("Connecting to database...")
    conn = psycopg2.connect(**DB_CONFIG)
    
    try:
        # Execute the entire SQL file (it should work as a single script)
        with conn.cursor() as cur:
            cur.execute(sql_content)
        
        conn.commit()
        print("✓ Customer management functions applied successfully!")
        
        # Verify the functions exist
        with conn.cursor() as cur:
            cur.execute("""
                SELECT routine_name 
                FROM information_schema.routines 
                WHERE routine_schema = 'agent_first_erp_crm' 
                AND routine_name IN ('add_customer', 'update_customer', 'get_followup_customers')
                ORDER BY routine_name;
            """)
            functions = cur.fetchall()
            print(f"\nCreated functions: {[f[0] for f in functions]}")
        
    except Exception as e:
        print(f"Error: {e}")
        conn.rollback()
        raise
    finally:
        conn.close()

if __name__ == "__main__":
    main()
