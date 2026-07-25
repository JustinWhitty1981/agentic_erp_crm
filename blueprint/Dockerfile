# Customer Service Agent - Dockerfile
# Simple, isolated Python environment for the customer service bot

FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for better caching
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy SQL migration and apply script
COPY 09_add_update_customer_functions.sql /app/
COPY apply_functions.py /app/
COPY test_create_functions.py /app/
COPY test_update_function.py /app/
COPY setup_customer_functions.py /app/
COPY verify_functions.py /app/

# Copy application code
COPY . .

# Create non-root user for security
RUN useradd -m -u 1000 agent
USER agent

# Set environment variables
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import psycopg2; print('DB check OK')" || exit 1

# Run the bot
CMD ["python", "bot.py"]
COPY test_functions.py /app/
