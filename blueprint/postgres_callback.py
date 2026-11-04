"""
PostgreSQL Callback Handler for LangChain Agent Logging

This callback handler logs all agent interactions to PostgreSQL,
including inputs, thoughts, tool calls, observations, and outputs.
"""

import os
import json
import psycopg2
from typing import Any, Dict, List, Optional
from langchain_core.callbacks import BaseCallbackHandler
from datetime import datetime
import uuid


class PostgresAgentLogger(BaseCallbackHandler):
    """Callback handler that logs agent interactions to PostgreSQL."""
    
    def __init__(self, conversation_id: str = None):
        self.conversation_id = conversation_id or str(uuid.uuid4())
        self.run_id = str(uuid.uuid4())
        self.start_time = None
        
    def get_db_connection(self):
        """Get PostgreSQL connection from environment variables."""
        return psycopg2.connect(
            host=os.getenv("POSTGRES_HOST", "localhost"),
            port=int(os.getenv("POSTGRES_PORT", 5432)),
            database=os.getenv("POSTGRES_DB", "agent_first_erp_crm"),
            user=os.getenv("POSTGRES_USER", "postgres"),
            password=os.getenv("POSTGRES_PASSWORD", ""),
        )
    
    # No schema here, on purpose. This class used to carry a _create_table_if_not_exists that ran
    # CREATE TABLE IF NOT EXISTS agent_interactions with twenty-one columns and four indexes, and it is
    # the clearest example in the tree of what "idempotent" fails to mean: on a migrated database the
    # statement is a no-op, and on one that is not yet migrated it *wins*, creating a table with no
    # tenant_id column - so no row-level security, because there is no column for the policy to read -
    # and adding indexes that lead on conversation_id rather than tenant_id, against 0006's rule that
    # every index on a tenant-coded table starts with the tenant. IF NOT EXISTS cannot tell the two
    # databases apart; that is the point of a migration file. Schema is owned by db/migrations, and a
    # process that cannot find agent_interactions should say so at startup rather than define its own.

    def on_llm_start(self, serialized: Dict[str, Any], prompts: List[str], **kwargs):
        """Called when the LLM starts running."""
        self.start_time = datetime.now()
        print(f"🔵 Agent started for conversation: {self.conversation_id}")
    
    def on_llm_end(self, response, **kwargs):
        """Called when the LLM finishes running."""
        duration_ms = int((datetime.now() - self.start_time).total_seconds() * 1000) if self.start_time else 0
        
        # Extract the final output
        final_output = response.generations[0][0].text if response.generations else ""
        
        conn = self.get_db_connection()
        try:
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO agent_interactions 
                    (conversation_id, run_id, final_output, duration_ms, model_used)
                    VALUES (%s, %s, %s, %s, %s)
                """, (self.conversation_id, self.run_id, final_output, duration_ms, "ornith:35b"))
            conn.commit()
            print(f"✅ Logged interaction {self.run_id} to agent_interactions")
        except Exception as e:
            print(f"❌ Error logging to database: {e}")
        finally:
            conn.close()
    
    def on_llm_error(self, error: BaseException, **kwargs):
        """Called when the LLM encounters an error."""
        conn = self.get_db_connection()
        try:
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO agent_interactions 
                    (conversation_id, run_id, error_message)
                    VALUES (%s, %s, %s)
                """, (self.conversation_id, self.run_id, str(error)))
            conn.commit()
        finally:
            conn.close()
    
    def on_tool_start(self, serialized: Dict[str, Any], input_str: str, **kwargs):
        """Called when a tool starts running."""
        print(f"🟡 Tool started: {serialized.get('name', 'unknown')}")
    
    def on_tool_end(self, output: str, **kwargs):
        """Called when a tool finishes running."""
        print(f"🟢 Tool completed: {output[:50]}...")
    
    def on_tool_error(self, error: BaseException, **kwargs):
        """Called when a tool encounters an error."""
        print(f"🔴 Tool error: {error}")


# Factory function to create logger with conversation context
def create_postgres_logger(conversation_id: str = None, **kwargs) -> PostgresAgentLogger:
    """Create a PostgresAgentLogger with optional conversation context."""
    logger = PostgresAgentLogger(conversation_id=conversation_id)
    # Set optional metadata
    for key, value in kwargs.items():
        setattr(logger, key, value)
    return logger
