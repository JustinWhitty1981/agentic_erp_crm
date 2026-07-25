#!/usr/bin/env python3
"""
Test the customer management functions.
"""

import os
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
        # Test add_customer
        print("Testing add_customer...")
        cur.execute("""
            SELECT * FROM add_customer(
                'Test', 'User', 'test@example.com', '+15551234567',
                '123 Test St', 'Test City', 'TX', '75001', 'US', 'active'
            )
        """)
        result = cur.fetchone()
        print(f"  Result: {result}")
        
        # Test get_followup_customers
        print("\nTesting get_followup_customers...")
        cur.execute("SELECT * FROM get_followup_customers(7)")
        results = cur.fetchall()
        print(f"  Found {len(results)} customers needing follow-up")
        for row in results[:3]:
            print(f"    - {row}")
        
        print("\n✓ All tests passed!")
        
except Exception as e:
    print(f"Error: {e}")
finally:
    conn.close()
