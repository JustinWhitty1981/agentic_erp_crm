"""
Quick test script to verify the agent works before connecting to Telegram.
"""

import os
from dotenv import load_dotenv
from langchain.agents import create_agent
from langchain_core.tools import tool
from langchain_ollama import ChatOllama
from langgraph.checkpoint.memory import InMemorySaver

load_dotenv()

# Test tools
@tool
def get_order_status(order_id: str) -> str:
    """Check order status."""
    return f"Order {order_id} is currently 'In Transit'."

@tool
def get_store_policy(topic: str) -> str:
    """Get store policy."""
    return f"Our {topic} policy is: 30-day returns with receipt."

TOOLS = [get_order_status, get_store_policy]

# Build agent
model = ChatOllama(
    model=os.getenv("OLLAMA_MODEL", "ornith:35b"),
    base_url=os.getenv("OLLAMA_BASE_URL", "http://localhost:11434"),
    temperature=0.7
)

checkpointer = InMemorySaver()
agent = create_agent(
    model=model,
    tools=TOOLS,
    system_prompt="You are a helpful customer service assistant.",
    checkpointer=checkpointer,
)

# Test conversation
thread_id = "test_user"
config = {"configurable": {"thread_id": thread_id}}

print("🧪 Testing Customer Service Agent...\n")

# Test 1: Simple question
print("📝 Test 1: Simple question")
result = agent.invoke(
    {"messages": [{"role": "user", "content": "What is your return policy?"}]},
    config=config
)
print(f"✅ Response: {result['messages'][-1].content}\n")

# Test 2: Tool call
print("📝 Test 2: Order status query (should trigger tool)")
result = agent.invoke(
    {"messages": [{"role": "user", "content": "What's the status of order ORD-99999?"}]},
    config=config
)
print(f"✅ Response: {result['messages'][-1].content}\n")

# Test 3: Memory test
print("📝 Test 3: Memory test (ask follow-up)")
result = agent.invoke(
    {"messages": [{"role": "user", "content": "What was my order ID again?"}]},
    config=config
)
print(f"✅ Response: {result['messages'][-1].content}\n")

print("🎉 All tests completed!")
