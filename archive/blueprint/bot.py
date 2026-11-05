"""
Simple Customer Service Agent using LangChain v1, Ollama, and PostgreSQL.
Based on the freeCodeCamp tutorial pattern.
Uses agent_first_erp_crm schema for customer data.
"""

import asyncio
import os
import re
from datetime import datetime
from typing import List, Optional

import psycopg2
from dotenv import load_dotenv
from langchain.agents import create_agent
from langchain_core.tools import tool
from langchain_ollama import ChatOllama
from langgraph.checkpoint.memory import InMemorySaver

# Import tools from individual modules
from tools.customer_lookup import get_customer_info
from tools.customer_communications import get_customer_communications
from tools.entity_stats import get_entity_stats
from tools.add_communication import add_communication
from tools.current_time import current_time
from tools.add_customer import add_customer_tool
from tools.update_customer import update_customer_tool
from tools.followup_customers import get_followup_customers_tool

from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes, MessageHandler, filters, ConversationHandler
import logging


def markdown_to_html(text: str) -> str:
    """Convert markdown bold (**text**) to HTML bold (<b>text</b>).
    Also escapes HTML special characters to prevent Telegram parsing errors.
    """
    # First, escape HTML special characters
    text = text.replace('&', '&amp;')
    text = text.replace('<', '&lt;')
    text = text.replace('>', '&gt;')
    
    # Then convert markdown bold to HTML bold
    # Match **text** but not if already inside HTML tags
    text = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', text)
    
    return text

# Set up logging
logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO
)
logger = logging.getLogger(__name__)

# Load environment variables
load_dotenv()

# --- Configuration ---
TELEGRAM_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
OLLAMA_URL = os.getenv("OLLAMA_BASE_URL", "http://{your-ollama-url}:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "ornith:35b")

# PostgreSQL Connection
DB_CONFIG = {
    "host": os.getenv("POSTGRES_HOST", "{your-postgres-host}"),
    "port": int(os.getenv("POSTGRES_PORT", 5432)),
    "database": os.getenv("POSTGRES_DB", "agent_first_erp_crm"),
    "user": os.getenv("POSTGRES_USER", "agent_first_erp_crm"),
    "password": os.getenv("POSTGRES_PASSWORD", "{yourpasswordhere}"),
}

# System Prompt
SYSTEM_PROMPT = (
    "You are a helpful customer service assistant with access to the agent_first_erp_crm database. "
    "You have tools to:\n"
    "- Look up customer information and communication history\n"
    "- View customer statistics\n"
    "- Log new interactions\n"
    "- **Add new customers** (individuals or businesses):\n"
    "  • For individuals: requires first name, last name, and at least one of email or phone\n"
    "  • For businesses: requires organization name and at least one of email or phone\n"
    "  • Optional: specify address_type (home, billing, shipping, office) and whether it's the primary address\n"
    "- **Update customer information** (search by name, then update fields like email, phone, address, status)\n"
    "- **List customers requiring follow-up** (those with unresolved issues or no recent contact)\n\n"
    "When you retrieve customer information or communication history, consider whether a real-world interaction just occurred. "
    "If the user mentions speaking to a customer, having a call, meeting, or any contact, proactively offer to log that interaction. "
    "For example:\n"
    "- User: 'I just spoke with Noah Smith about their order.'\n"
    "- You: 'Great! Would you like me to log this communication? If so, please provide a brief summary of what was discussed.'\n\n"
    "To add a new customer:\n"
    "• For individuals: ask for first name, last name, at least one contact method (email or phone), and address if available.\n"
    "• For businesses: ask for the organization name, at least one contact method, and optionally a contact person's name.\n"
    "• You can specify the address type (home, billing, shipping, office) and whether it's the primary address.\n\n"
    "To update a customer, first identify them by name, then specify what information needs to be changed. "
    "To find customers needing follow-up, use the follow-up tool.\n\n"
    "Use tools when the user's request needs one. If the question doesn't need a tool, answer directly. "
    "If a tool returns an error, explain the error plainly. Keep responses friendly and concise."
)

# --- Tools List ---
TOOLS = [
    get_customer_info, 
    get_customer_communications, 
    get_entity_stats, 
    current_time, 
    add_communication,
    add_customer_tool,
    update_customer_tool,
    get_followup_customers_tool
]

# --- Agent Builder ---

def build_agent():
    """Build the LangChain agent with tools and memory."""
    model = ChatOllama(model=OLLAMA_MODEL, base_url=OLLAMA_URL, temperature=0.7)
    checkpointer = InMemorySaver()
    
    agent = create_agent(
        model=model,
        tools=TOOLS,
        system_prompt=SYSTEM_PROMPT,
        checkpointer=checkpointer,
    )
    
    return agent

# --- Telegram Bot Integration ---

STATE_NONE, STATE_WAITING_FOR_ORDER_ID, STATE_WAITING_FOR_POLICY_TOPIC = range(3)

agent = build_agent()

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    """Start the conversation."""
    response = (
        "Hello! I'm your customer service assistant. \n"
        "I can help you with:\n"
        "- Looking up customer information (individuals and businesses)\n"
        "- Checking communication history\n"
        "- Viewing customer statistics\n"
        "- **Adding new customers**:\n"
        "  • Individuals: provide first name, last name, email/phone, and address\n"
        "  • Businesses: provide organization name, email/phone, and optional contact person\n"
        "  • Specify address type (home, billing, shipping, office) if needed\n"
        "- **Updating customer information** (change contact details, address, or status)\n"
        "- **Finding customers needing follow-up**\n"
        "- General questions\n\n"
        "How can I help you today?"
    )
    await update.message.reply_text(markdown_to_html(response), parse_mode='HTML')
    return STATE_NONE

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    """Handle user messages and route to the agent."""
    user_id = update.effective_user.id
    user_message = update.message.text
    
    logger.info(f"Received message from user {user_id}: {user_message[:50]}...")
    
    thread_id = f"user_{user_id}"
    config = {"configurable": {"thread_id": thread_id}}
    
    try:
        loop = asyncio.get_event_loop()
        result = await loop.run_in_executor(
            None,
            lambda: agent.invoke(
                {"messages": [{"role": "user", "content": user_message}]},
                config=config,
            )
        )
        
        response = result["messages"][-1].content
        # Convert markdown bold to HTML and escape special characters
        safe_response = markdown_to_html(response)
        logger.info(f"Sending response to User {user_id}")
        await update.message.reply_text(safe_response, parse_mode='HTML')
        
    except Exception as e:
        logger.error(f"Error processing message for user {user_id}: {e}")
        error_msg = f"Sorry, I encountered an error: {e}"
        await update.message.reply_text(markdown_to_html(error_msg), parse_mode='HTML')
    
    return STATE_NONE

async def cancel(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    """Cancel the conversation."""
    await update.message.reply_text("Conversation cancelled.")
    return STATE_NONE


def main():
    """Start the Telegram bot."""
    if not TELEGRAM_TOKEN:
        logger.error("TELEGRAM_BOT_TOKEN not set!")
        return
    
    logger.info("Starting customer service bot...")
    logger.info(f"Using Ollama model: {OLLAMA_MODEL}")
    
    # Build the application
    application = Application.builder().token(TELEGRAM_TOKEN).build()
    
    # Register handlers
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))
    
    # Start the bot
    logger.info("Bot is running! Waiting for messages...")
    application.run_polling()


if __name__ == "__main__":
    main()