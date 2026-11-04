"""
Tool Logger for Agent First ERP CRM

A wrapper that records every tool invocation a run makes, so ADR-001's promise - "we log every tool
call" - is kept by something other than a hope.

This module does not touch the database, and that is the whole content of the change. It used to
`CREATE TABLE IF NOT EXISTS agent_tool_calls` on first use and INSERT a row per call, which was wrong
three times over:

  - **Code creating schema** is the inverse of ADR-002. The table had no migration, so it existed only
    on databases where this module happened to run, and `IF NOT EXISTS` meant a later, different
    definition would never replace the first one it met. dev/README's "two heads" failure mode,
    arriving from the application side.
  - **A second tool-call table** duplicates `agent_interactions.actions_taken` / `tool_observations`,
    which is what `vw_tool_calls` and `vw_tool_performance` derive from. Two copies of one fact, and
    the dashboard reads the one this module never wrote to.
  - **The DDL never ran anyway.** The INSERT was qualified to `agent_first_erp_crm`, the schema review
    3.1 measured no migration creates, so the statement failed and `except: print` swallowed it. The
    module's name promised a trail that was not being written, which is the most expensive kind of
    bug: the absence is invisible exactly when it matters.

So the accumulation lives here and the write lives in `interaction_logger.log_agent_trajectory`, one
row per run, with the two arrays aligned by position - the contract `vw_tool_calls` depends on. A tool
that runs and never gets flushed is a run that never ended; the pending calls stay in `_calls` where a
`take()` can still find them.
"""

import json
import threading
from datetime import datetime, timezone
from typing import Any, Callable, Dict, List, Optional

from langchain_core.tools import Tool


class ToolLogger:
    """Accumulates the tool calls made inside one run, in process memory."""

    _lock = threading.Lock()
    _calls: Dict[str, List[Dict[str, Any]]] = {}

    @classmethod
    def log_tool_call(
        cls,
        conversation_id: str,
        run_id: str,
        tool_name: str,
        tool_input: Any,
        tool_output: Any,
        duration_ms: int,
        error: Optional[str] = None
    ) -> None:
        """Note one invocation against its run.

        `conversation_id` is kept in the record rather than used to find one: the row this becomes is
        keyed by run_id, and a call recorded under a run that is not the conversation's current row is
        a mismatch worth seeing in the JSON instead of one worth silently discarding.

        An empty `run_id` is the case to notice. The wrapper below takes it from the caller, and a
        caller that lost it would otherwise append every orphan call to one bucket and the trajectory
        would attribute an agent's whole uptime to a single run.
        """
        if not run_id:
            run_id = "(unattributed)"
        entry = {
            "tool": tool_name,
            "tool_input": _jsonable(tool_input),
            "output": _jsonable(tool_output),
            "type": "error" if error else type(tool_output).__name__,
            "duration_ms": duration_ms,
            "conversation_id": conversation_id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        if error:
            entry["error"] = error
        with cls._lock:
            cls._calls.setdefault(run_id, []).append(entry)

    @classmethod
    def pending(cls, run_id: str) -> int:
        """How many calls are waiting to be written. A count, not a dump: the caller is usually a
        health check or a test, and neither wants the payloads."""
        with cls._lock:
            return len(cls._calls.get(run_id, []))

    @classmethod
    def take(cls, run_id: str) -> List[Dict[str, Any]]:
        """Remove and return a run's calls, in the order they ran.

        Removal is part of the contract, not a convenience: a caller that logs the trajectory and then
        crashes before the next turn would otherwise flush the same calls into a second row on retry,
        and `vw_tool_performance` counts calls per row, so the tool would look twice as slow as it is.
        """
        with cls._lock:
            return cls._calls.pop(run_id, [])


def _jsonable(value: Any) -> Any:
    """Anything a tool returned, as something jsonb can hold.

    The old code passed a bare Python object to a jsonb column and let psycopg2 adapt it, which works
    for dict and str and raises for anything with a __repr__ the driver cannot map - a DataFrame from a
    hypothetical reporting tool, or a Decimal from a money column. Stringifying at the boundary makes
    the loss visible in the record rather than in a traceback inside the logger.
    """
    if value is None or isinstance(value, (bool, int, float, str, dict, list)):
        return value
    try:
        return json.loads(json.dumps(value, default=str))
    except (TypeError, ValueError):
        return str(value)


def create_logged_tool(tool: Tool, conversation_id: str, run_id: str) -> Tool:
    """
    Wrap a tool to log all invocations.

    Args:
        tool: The original LangChain Tool
        conversation_id: UUID for the conversation
        run_id: UUID for this specific run

    Returns:
        A new Tool that records all calls against `run_id`

    The wrapper changes no behaviour of the tool it wraps: the same arguments, the same return value,
    and an exception still propagates after being recorded. A wrapper that swallowed errors would
    report a failed call as a successful observation, and the trail would say the agent saw something
    it did not.
    """
    original_func = tool.func

    def logged_func(*args, **kwargs):
        start_time = datetime.now()
        tool_input = args[0] if args else kwargs

        try:
            result = original_func(*args, **kwargs)
            duration_ms = int((datetime.now() - start_time).total_seconds() * 1000)
            ToolLogger.log_tool_call(
                conversation_id=conversation_id,
                run_id=run_id,
                tool_name=tool.name,
                tool_input=tool_input,
                tool_output=result,
                duration_ms=duration_ms,
            )
            return result

        except Exception as e:
            duration_ms = int((datetime.now() - start_time).total_seconds() * 1000)
            ToolLogger.log_tool_call(
                conversation_id=conversation_id,
                run_id=run_id,
                tool_name=tool.name,
                tool_input=tool_input,
                tool_output=None,
                duration_ms=duration_ms,
                error=str(e),
            )
            raise

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
        List of wrapped tools that record all calls
    """
    return [create_logged_tool(tool, conversation_id, run_id) for tool in tools]


def logged_tools(tools: list, conversation_id: str, run_id: str) -> list:
    """Compatibility alias for create_logged_tools."""
    return create_logged_tools(tools, conversation_id, run_id)
