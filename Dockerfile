# Use lightweight Python base
FROM python:3.11-alpine

# Set working directory
WORKDIR /app

# Copy requirements first (for better layer caching)
COPY requirements.txt .

# Install build tools & dependencies
RUN apk add --no-cache \
    build-base \
    libffi-dev \
    gcc \
    musl-dev \
    tar \
    ca-certificates \
    && pip install --no-cache-dir -r requirements.txt

# Copy the rest of the app
COPY . .

# Default environment
ENV DOCKER_SOCKET=/var/run/docker.sock
ENV PYTHONUNBUFFERED=1

# Run as non-root user for security
RUN adduser -D appuser
USER appuser

# Expose default MCP port
EXPOSE 8000

# Start the MCP server
CMD ["python3", "docker_mcp_server.py"]
