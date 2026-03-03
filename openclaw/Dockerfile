FROM node:22-slim

RUN apt-get update && apt-get install -y \
    curl \
    git \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Install OpenClaw globally
RUN npm install -g openclaw

COPY openclaw/entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

# Seed workspace files — copied to volume on first container start
COPY workspace/ /workspace-seed/

EXPOSE 18789 18791

ENTRYPOINT ["/entrypoint.sh"]
