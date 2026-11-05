"""
Current Time Tool - Return the current local date and time.
"""

from datetime import datetime
from langchain_core.tools import tool


@tool
def current_time() -> str:
    """Return the current local date and time.
    Use this when the user asks what time it is.
    """
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")