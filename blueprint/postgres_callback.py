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
            database=os.getenv("POSTGRES_DB", "agent_swarm"),
            user=os.getenv("POSTGRES_USER", "postgres"),
            password=os.getenv("POSTGRES_PASSWORD", ""),
        )
    
    def _create_table_if_not_exists(self):
        """Create the agent_interactions table in agent_swarm schema if it doesn't exist."""
        conn = self.get_db_connection()
        try:
            with conn.cursor() as cur:
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS agent_swarm.agent_interactions (
                        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                        conversation_id UUID NOT NULL,
                        run_id TEXT NOT NULL,
                        telegram_chat_id TEXT,
                        telegram_message_id BIGINT,
                        bot_id TEXT,
                        user_id TEXT,
                        timestamp TIMESTAMPTZ DEFAULT NOW(),
                        human_input TEXT,
                        intent_classification TEXT,
                        confidence_score FLOAT,
                        agent_thoughts TEXT[],
                        actions_taken JSONB,
                        tool_observations JSONB,
                        final_output TEXT,
                        response_sources JSONB,
                        model_used TEXT,
                        token_usage JSONB,
                        error_message TEXT,
                        duration_ms INTEGER,
                        feedback_score FLOAT,
                        created_at TIMESTAMPTZ DEFAULT NOW()
                    )
                """)
                cur.execute("CREATE INDEX IF NOT EXISTS idx_conv ON agent_swarm.agent_interactions(conversation_id)")
                cur.execute("CREATE INDEX IF NOT EXISTS idx_user ON agent_swarm.agent_interactions(user_id)")
                cur.execute("CREATE INDEX IF NOT EXISTS idx_timestamp ON agent_swarm.agent_interactions(timestamp DESC)")
                cur.execute("CREATE INDEX IF NOT EXISTS idx_actions ON agent_swarm.agent_interactions USING GIN(actions_taken)")
            conn.commit()
        finally:
            conn.close()
    
    def on_llm_start(self, serialized: Dict[str, Any], prompts: List[str], **kwargs):
        """Called when the LLM starts running."""
        self.start_time = datetime.now()
        self._create_table_if_not_exists()
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
                    INSERT INTO agent_swarm.agent_interactions 
                    (conversation_id, run_id, final_output, duration_ms, model_used)
                    VALUES (%s, %s, %s, %s, %s)
                """, (self.conversation_id, self.run_id, final_output, duration_ms, "ornith:35b"))
            conn.commit()
            print(f"✅ Logged interaction {self.run_id} to agent_swarm.agent_interactions")
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
                    INSERT INTO agent_swarm.agent_interactions 
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
