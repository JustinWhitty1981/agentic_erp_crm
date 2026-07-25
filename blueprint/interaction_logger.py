"""
Interaction Logger for Agent Swarm

This module provides enterprise-grade logging for all agent-human interactions.
It captures the full "trajectory" of an agent's reasoning, actions, and outcomes
to enable debugging, auditing, and performance analysis.

Usage:
    from tools.interaction_logger import log_agent_trajectory
    
    log_id = log_agent_trajectory(
        conversation_id="uuid-here",
        telegram_chat_id="8551240949",
        telegram_message_id=7593,
        bot_id="jarvis-main",
        user_id="8551240949",
        human_input="Find Suzy Smith's contact info",
        intermediate_steps=agent_response["intermediate_steps"],
        final_output="Found 2 matches for Suzy Smith...",
        model_used="qwen3.5:122b"
    )
"""

import os
import json
import psycopg2
from typing import List, Dict, Any, Optional
from datetime import datetime
import uuid
import logging

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def get_db_connection():
    """
    Get PostgreSQL connection from environment variables.
    
    Returns:
        psycopg2 connection object
    
    Raises:
        psycopg2.OperationalError: If connection fails
    """
    return psycopg2.connect(
        host=os.getenv("POSTGRES_HOST", "localhost"),
        port=int(os.getenv("POSTGRES_PORT", 5432)),
        database=os.getenv("POSTGRES_DB", "agent_swarm"),
        user=os.getenv("POSTGRES_USER", "postgres"),
        password=os.getenv("POSTGRES_PASSWORD", ""),
    )


def log_agent_trajectory(
    conversation_id: str,
    telegram_chat_id: str,
    telegram_message_id: Optional[int],
    bot_id: str,
    user_id: str,
    human_input: str,
    intermediate_steps: List[tuple],
    final_output: str,
    model_used: str = "qwen3.5:122b",
    token_usage: Optional[Dict] = None,
    error: Optional[str] = None,
    duration_ms: Optional[int] = None,
    intent_classification: Optional[str] = None,
    confidence_score: Optional[float] = None,
    response_sources: Optional[List] = None
) -> str:
    """
    Logs the full agent trajectory to the database.
    
    This function captures:
    - Who asked (Telegram user)
    - What they asked (human_input)
    - How the agent thought (agent_thoughts)
    - What tools it used (actions_taken)
    - What it found (tool_observations)
    - What it said back (final_output)
    
    Args:
        conversation_id: UUID linking related messages in a conversation
        telegram_chat_id: The Telegram chat ID (e.g., "8551240949")
        telegram_message_id: The specific message ID that triggered this interaction
        bot_id: Identifier for the bot instance (e.g., "jarvis-main")
        user_id: The user's Telegram ID
        human_input: The original user prompt
        intermediate_steps: List of (AgentAction, observation) tuples from LangChain
        final_output: The final answer given to the user
        model_used: Which LLM model processed this request
        token_usage: Dict with 'input' and 'output' token counts
        error: Error message if the interaction failed
        duration_ms: Total time taken for the interaction in milliseconds
        intent_classification: Auto-detected intent (e.g., "customer_lookup")
        confidence_score: Model's confidence in the intent (0.0-1.0)
        response_sources: List of record IDs that were used in the response
        
    Returns:
        str: The UUID of the created interaction record, or None if failed
        
    Example:
        >>> log_id = log_agent_trajectory(
        ...     conversation_id="abc-123",
        ...     telegram_chat_id="8551240949",
        ...     telegram_message_id=7593,
        ...     bot_id="jarvis-main",
        ...     user_id="8551240949",
        ...     human_input="Find Suzy Smith",
        ...     intermediate_steps=[(action1, obs1), (action2, obs2)],
        ...     final_output="Found 2 matches...",
        ...     model_used="qwen3.5:122b"
        ... )
        >>> print(f"Logged interaction: {log_id}")
    """
    conn = None
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        
        # Extract structured data from LangChain's intermediate_steps
        thoughts = []
        actions = []
        observations = []
        
        for action, observation in intermediate_steps:
            # action is an AgentAction object with attributes: tool, tool_input, log
            thoughts.append(action.log)  # The full "Thought: ... Action: ..." block
            actions.append({
                "tool": action.tool,
                "tool_input": str(action.tool_input),
                "log": action.log,
                "timestamp": datetime.now().isoformat()
            })
            
            # observation can be string, dict, list, or error
            if isinstance(observation, (str, dict, list)):
                obs_data = observation
            else:
                obs_data = str(observation)
                
            observations.append({
                "output": obs_data,
                "type": type(observation).__name__,
                "timestamp": datetime.now().isoformat()
            })

        # Insert into DB
        cur.execute("""
            INSERT INTO agent_interactions 
            (conversation_id, telegram_chat_id, telegram_message_id, bot_id, user_id,
             human_input, intent_classification, confidence_score,
             agent_thoughts, actions_taken, tool_observations, 
             final_output, response_sources, model_used, token_usage, 
             error_message, duration_ms)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            RETURNING id;
        """, (
            conversation_id,
            telegram_chat_id,
            telegram_message_id,
            bot_id,
            user_id,
            human_input,
            intent_classification,
            confidence_score,
            thoughts,
            json.dumps(actions),  # Single JSON array, not array of JSONB
            json.dumps(observations),  # Single JSON array, not array of JSONB
            final_output,
            json.dumps(response_sources or []),
            model_used,
            json.dumps(token_usage or {}),
            error,
            duration_ms
        ))
        
        interaction_id = cur.fetchone()[0]
        conn.commit()
        cur.close()
        
        logger.info(f"Logged interaction {interaction_id} for user {user_id}")
        return str(interaction_id)

    except Exception as e:
        logger.error(f"Failed to log interaction: {e}")
        if conn:
            conn.rollback()
        return None
    finally:
        if conn:
            conn.close()


def get_interaction_summary(interaction_id: str) -> Optional[Dict]:
    """
    Retrieve a summary of a specific interaction.
    
    Args:
        interaction_id: UUID of the interaction to retrieve
        
    Returns:
        Dict with interaction details, or None if not found
    """
    conn = None
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        
        cur.execute("""
            SELECT 
                id, telegram_chat_id, user_id, human_input,
                actions_taken, final_output, error_message,
                duration_ms, timestamp
            FROM agent_interactions
            WHERE id = %s;
        """, (interaction_id,))
        
        row = cur.fetchone()
        if row:
            return {
                "id": str(row[0]),
                "telegram_chat_id": row[1],
                "user_id": row[2],
                "human_input": row[3],
                "actions_taken": row[4],
                "final_output": row[5],
                "error_message": row[6],
                "duration_ms": row[7],
                "timestamp": row[8].isoformat() if row[8] else None
            }
        return None
        
    finally:
        if conn:
            conn.close()


def search_interactions(
    query: str,
    user_id: Optional[str] = None,
    limit: int = 10
) -> List[Dict]:
    """
    Search interactions by human input text.
    
    Args:
        query: Search query (full-text search)
        user_id: Optional filter by user
        limit: Maximum results to return
        
    Returns:
        List of interaction summaries matching the query
    """
    conn = None
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        
        if user_id:
            cur.execute("""
                SELECT id, telegram_chat_id, user_id, human_input,
                       final_output, timestamp
                FROM agent_interactions
                WHERE to_tsvector('english', human_input) @@ to_tsquery(%s)
                  AND user_id = %s
                ORDER BY timestamp DESC
                LIMIT %s;
            """, (query, user_id, limit))
        else:
            cur.execute("""
                SELECT id, telegram_chat_id, user_id, human_input,
                       final_output, timestamp
                FROM agent_interactions
                WHERE to_tsvector('english', human_input) @@ to_tsquery(%s)
                ORDER BY timestamp DESC
                LIMIT %s;
            """, (query, limit))
        
        results = []
        for row in cur.fetchall():
            results.append({
                "id": str(row[0]),
                "telegram_chat_id": row[1],
                "user_id": row[2],
                "human_input": row[3],
                "final_output": row[4],
                "timestamp": row[5].isoformat() if row[5] else None
            })
        
        return results
        
    finally:
        if conn:
            conn.close()


# ============================================================================
# EXAMPLE USAGE
# ============================================================================

if __name__ == "__main__":
    # Example: Log a test interaction
    test_log_id = log_agent_trajectory(
        conversation_id=str(uuid.uuid4()),
        telegram_chat_id="8551240949",
        telegram_message_id=7593,
        bot_id="jarvis-main",
        user_id="8551240949",
        human_input="Test interaction logging",
        intermediate_steps=[],
        final_output="This is a test",
        model_used="qwen3.5:122b",
        duration_ms=150
    )
    
    if test_log_id:
        print(f"✅ Successfully logged test interaction: {test_log_id}")
        
        # Retrieve it
        summary = get_interaction_summary(test_log_id)
        print(f"Retrieved summary: {summary}")
        
        # Search for it
        results = search_interactions("test")
        print(f"Search results: {len(results)} found")
    else:
        print("❌ Failed to log test interaction")
