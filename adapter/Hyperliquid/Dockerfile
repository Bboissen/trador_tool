FROM python:3.13-alpine

# Set working directory
WORKDIR /app

# Install git and other necessary tools for building
RUN apk add --no-cache \
    git \
    curl \
    gcc \
    musl-dev \
    linux-headers \
    libffi-dev

# Clone the official Hyperliquid Python SDK
RUN git clone https://github.com/hyperliquid-dex/hyperliquid-python-sdk.git /tmp/hyperliquid-sdk && \
    cd /tmp/hyperliquid-sdk && \
    pip install --no-cache-dir -e . && \
    rm -rf /tmp/hyperliquid-sdk/.git

# Copy application requirements and install
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Remove build dependencies to reduce image size
RUN apk del gcc musl-dev linux-headers libffi-dev

# Copy application files
COPY main.py .
COPY healthcheck.py .
COPY runtime_config.py .

# Create a non-root user (Alpine uses adduser instead of useradd)
RUN adduser -D -u 1000 hyperliquid && \
    chown -R hyperliquid:hyperliquid /app

USER hyperliquid

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=5 \
    CMD python healthcheck.py || exit 1

# Run the application
CMD ["python", "-u", "main.py"]
