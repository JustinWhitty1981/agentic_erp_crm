"""
Tool Logger for Agent Swarm

This module provides a wrapper for LangChain tools that logs all tool calls
and observations to PostgreSQL for full interaction tracing.
"""

import os
import json
import psycopg2
from typing import Any, Callable
from datetime import datetime
from langchain_core.tools import Tool
import uuid


class ToolLogger:
    """Logs all tool invocations to PostgreSQL."""
    
    _connection_cache = None
    
    @classmethod
    def get_db_connection(cls):
        """Get or create a PostgreSQL connection."""
        if cls._connection_cache is None:
            cls._connection_cache = psycopg2.connect(
                host=os.getenv("POSTGRES_HOST", "localhost"),
                port=int(os.getenv("POSTGRES_PORT", 5432)),
                database=os.getenv("POSTGRES_DB", "agent_swarm"),
                user=os.getenv("POSTGRES_USER", "postgres"),
                password=os.getenv("POSTGRES_PASSWORD", ""),
            )
        return cls._connection_cache
    
    @classmethod
    def log_tool_call(
        cls,
        conversation_id: str,
        run_id: str,
        tool_name: str,
        tool_input: Any,
        tool_output: Any,
        duration_ms: int,
        error: str = None
    ):
        """Log a single tool invocation."""
        conn = None
        try:
            conn = cls.get_db_connection()
            cur = conn.cursor()
            
            # Ensure the table exists
            cur.execute("""
                CREATE TABLE IF NOT EXISTS agent_swarm.agent_tool_calls (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    conversation_id UUID NOT NULL,
                    run_id TEXT NOT NULL,
                    tool_name TEXT NOT NULL,
                    tool_input JSONB,
                    tool_output JSONB,
                    duration_ms INTEGER,
                    error_message TEXT,
                    timestamp TIMESTAMPTZ DEFAULT NOW()
                )
            """)
            cur.execute("CREATE INDEX IF NOT EXISTS idx_tool_conv ON agent_swarm.agent_tool_calls(conversation_id)")
            cur.execute("CREATE INDEX IF NOT EXISTS idx_tool_run ON agent_swarm.agent_tool_calls(run_id)")
            cur.execute("CREATE INDEX IF NOT EXISTS idx_tool_name ON agent_swarm.agent_tool_calls(tool_name)")
            
            # Insert the tool call
            cur.execute("""
                INSERT INTO agent_swarm.agent_tool_calls
                (conversation_id, run_id, tool_name, tool_input, tool_output, duration_ms, error_message)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
            """, (
                conversation_id,
                run_id,
                tool_name,
                json.dumps(tool_input) if not isinstance(tool_input, (str, int, float, bool, type(None))) else tool_input,
                json.dumps(tool_output) if not isinstance(tool_output, (str, int, float, bool, type(None))) else tool_output,
                duration_ms,
                error
            ))
            
            conn.commit()
            cur.close()
            
        except Exception as e:
            print(f"❌ Error logging tool call: {e}")
        finally:
            if conn:
                try:
                    conn.close()
                    cls._connection_cache = None
                except:
                    pass


def create_logged_tool(tool: Tool, conversation_id: str, run_id: str) -> Tool:
    """
    Wrap a tool to log all invocations.
    
    Args:
        tool: The original LangChain Tool
        conversation_id: UUID for the conversation
        run_id: UUID for this specific run
        
    Returns:
        A new Tool that logs all calls to PostgreSQL
    """
    original_func = tool.func
    
    def logged_func(*args, **kwargs):
        start_time = datetime.now()
        tool_input = args[0] if args else kwargs
        
        try:
            # Execute the original tool
            result = original_func(*args, **kwargs)
            
            # Calculate duration
            duration_ms = int((datetime.now() - start_time).total_seconds() * 1000)
            
            # Log the successful call
            ToolLogger.log_tool_call(
                conversation_id=conversation_id,
                run_id=run_id,
                tool_name=tool.name,
                tool_input=tool_input,
                tool_output=result,
                duration_ms=duration_ms
            )
            
            return result
            
        except Exception as e:
            # Log the error
            duration_ms = int((datetime.now() - start_time).total_seconds() * 1000)
            ToolLogger.log_tool_call(
                conversation_id=conversation_id,
                run_id=run_id,
                tool_name=tool.name,
                tool_input=tool_input,
                tool_output=None,
                duration_ms=duration_ms,
                error=str(e)
            )
            raise
    
    # Create a new Tool with the logged function
    return Tool(
        name=tool.name,
        func=logged_func,
        description=tool.description
    )


def create_logged_tools(tools: list, conversation_id: str, run_id: str) -> list:
    """
    Wrap all tools in a list to log their invocations.
    
    Args:
        tools: List of LangChain Tools
        conversation_id: UUID for the conversation
        run_id: UUID for this specific run
        
    Returns:
        List of wrapped tools that log all calls
    """
    return [create_logged_tool(tool, conversation_id, run_id) for tool in tools]
