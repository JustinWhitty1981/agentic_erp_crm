import os
from dotenv import load_dotenv
load_dotenv()
#!/usr/bin/env python3
"""
Verify customer management functions exist.
"""

import psycopg2

DB_CONFIG = {
    "host": os.getenv("POSTGRES_HOST", "localhost"),
    "port": int(os.getenv("POSTGRES_PORT", "5432")),
    "database": os.getenv("POSTGRES_DB", "agent_swarm"),
    "user": os.getenv("POSTGRES_USER", "postgres"),
    "password": os.getenv("POSTGRES_PASSWORD", ""),
}

conn = psycopg2.connect(**DB_CONFIG)
try:
    with conn.cursor() as cur:
        # Check all functions in the database
        cur.execute("""
            SELECT n.nspname as schemaname, p.proname, p.proargnames
            FROM pg_proc p
            JOIN pg_namespace n ON p.pronamespace = n.oid
            WHERE p.proname IN ('add_customer', 'update_customer', 'get_followup_customers')
            ORDER BY n.nspname, p.proname;
        """)
        functions = cur.fetchall()
        if functions:
            print("Found functions:")
            for schema, name, args in functions:
                print(f"  - {schema}.{name} (args: {args})")
        else:
            print("No functions found with those names")
        
        # List all functions in agent_swarm schema
        cur.execute("""
            SELECT proname, proargnames
            FROM pg_proc
            WHERE pronamespace = 'agent_swarm'::regnamespace
            ORDER BY proname;
        """)
        all_funcs = cur.fetchall()
        print(f"\nAll functions in agent_swarm: {len(all_funcs)}")
        for name, args in all_funcs[:10]:
            print(f"  - {name} (args: {args})")
        if len(all_funcs) > 10:
            print(f"  ... and {len(all_funcs) - 10} more")
        
except Exception as e:
    print(f"Error: {e}")
finally:
    conn.close()
