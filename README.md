# OpenClaw Docker Stack

> **One-command local AI assistant** — OpenClaw + Ollama on your GPU, secured with HTTPS, accessible from any browser or WhatsApp.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./License)
[![Docker](https://img.shields.io/badge/Docker-Compose-blue?logo=docker)](https://docs.docker.com/compose/)
[![Ollama](https://img.shields.io/badge/Powered%20by-Ollama-black)](https://ollama.com)
[![OpenClaw](https://img.shields.io/badge/Gateway-OpenClaw-orange)](https://openclaw.ai)
[![GPU](https://img.shields.io/badge/GPU-NVIDIA%20CUDA-76B900?logo=nvidia)](https://developer.nvidia.com/cuda)
[![Stars](https://img.shields.io/github/stars/CloudsDocker/OpenClaw?style=social)](https://github.com/CloudsDocker/OpenClaw/stargazers)

---

## Why this project?

Running a local AI assistant normally requires:
- Installing Ollama manually
- Configuring OpenClaw authentication
- Setting up HTTPS (browsers block non-secure AI features)
- Handling WSL2 / Windows networking quirks

**This stack does all of that for you** — one `docker compose up -d` and you have a private, GPU-accelerated AI assistant running on your own hardware with no cloud API fees.

---

## Features

- **100% local** — your data never leaves your machine
- **GPU-accelerated** — NVIDIA CUDA via Docker device reservations
- **Zero-config HTTPS** — Caddy issues a local CA certificate automatically
- **Auto model registration** — detects and registers Ollama models on every start
- **Windows / WSL2 ready** — includes port-proxy instructions for browser access
- **WhatsApp integration** — chat with your assistant from your phone
- **Persistent storage** — models, sessions, and config survive restarts

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  Docker (Linux / WSL2)                               │
│                                                      │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────┐  │
│  │  openclaw-  │───▶│  openclaw-   │───▶│  caddy  │  │
│  │  ollama     │    │  gateway     │    │  :18790 │  │
│  │  (GPU)      │    │  :18789      │    │  HTTPS  │  │
│  └─────────────┘    └──────────────┘    └─────────┘  │
└──────────────────────────────────────────────────────┘
                                               │
                                               ▼
                                    Windows browser / WhatsApp
```

| Container | Role |
|-----------|------|
| `openclaw-ollama` | Runs the LLM on your GPU |
| `openclaw-model-init` | Pulls the model on first start (then exits) |
| `openclaw-gateway` | OpenClaw AI gateway + web UI |
| `openclaw-caddy` | HTTPS reverse proxy with automatic local TLS |

---

## Requirements

| Requirement | Details |
|-------------|---------|
| OS | Linux or WSL2 (Windows 11) |
| GPU | NVIDIA RTX 3080 / 4080 / 5080 or equivalent (8 GB+ VRAM) |
| RAM | 16 GB+ recommended |
| Docker | Docker Desktop or Docker Engine with NVIDIA Container Runtime |
| Disk | ~10 GB free for the default model |

Verify NVIDIA runtime is available:

```bash
docker info | grep -i nvidia
# Expected:  Runtimes: ... nvidia ...
```

---

## Quick Start

```bash
# 1. Clone
git clone https://github.com/CloudsDocker/OpenClaw.git
cd OpenClaw

# 2. Set your gateway token
cp .env.example .env
# Edit .env and set OPENCLAW_GATEWAY_TOKEN to a strong random value:
#   openssl rand -hex 24

# 3. Start everything (first run pulls ~9 GB model — be patient)
docker compose up -d

# 4. Watch startup progress
docker compose logs -f openclaw
```

When you see `listening on ws://0.0.0.0:18789` the gateway is ready.

---

## Accessing the UI

### Linux (direct)

```
https://localhost:18790/#token=<your_OPENCLAW_GATEWAY_TOKEN>
```

### Windows (WSL2)

Follow the one-time setup steps below, then open:

```
https://localhost:18790/#token=<your_OPENCLAW_GATEWAY_TOKEN>
```

---

## One-time Setup (WSL2 + Windows)

### 1. Trust the Caddy HTTPS certificate in Windows

```bash
# Export the root CA to your Windows filesystem
docker exec openclaw-caddy cat /data/caddy/pki/authorities/local/root.crt \
  > /mnt/c/Users/Public/caddy-root.crt
```

In Windows:
1. `Win + R` → `certmgr.msc` → Enter
2. **Trusted Root Certification Authorities** → **Certificates**
3. Right-click → **All Tasks** → **Import**
4. Select `C:\Users\Public\caddy-root.crt`
5. Place in **Trusted Root Certification Authorities**
6. Fully restart Chrome / Edge

### 2. Set up Windows port proxy (run once in PowerShell as Administrator)

```powershell
# Replace 172.x.x.x with your actual WSL2 IP (run: hostname -I in WSL2)
netsh interface portproxy add v4tov4 listenport=18790 listenaddress=127.0.0.1 connectport=18790 connectaddress=172.25.75.125
netsh interface portproxy add v6tov4 listenport=18790 listenaddress=::1    connectport=18790 connectaddress=172.25.75.125
```

> If the WSL2 IP changes after a reboot, re-run with the new IP (`hostname -I | awk '{print $1}'`).

### 3. Install helper scripts

```bash
bash install-tools.sh
```

### 4. Approve the browser pairing (first connection only)

The first time your browser connects it sends a device pairing request.
Approve it with:

```bash
openclaw-approve
```

Expected output:
```
Approving a7f55f7c-9188-447b-af86-cb433e55198f ...
Approved <device-id>
```

You only need to approve once per browser profile.

---

## Configuration

### Change the model

Edit `docker-compose.yml`:

```yaml
OPENCLAW_MODEL=ollama/qwen3:14b
```

Recommended models for RTX 5080 (16 GB VRAM):

| Model | VRAM | Notes |
|-------|------|-------|
| `ollama/qwen3:14b` | ~10 GB | Best quality, default |
| `ollama/qwen3:8b`  | ~6 GB  | Faster, lighter |
| `ollama/llama3.1:latest` | ~5 GB | Good general fallback |

Model must support tool calling (qwen3 and llama3.1 do; phi4 does not).

### Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OPENCLAW_GATEWAY_TOKEN` | Yes | Authentication token for the web UI |
| `OPENCLAW_MODEL` | No | Model to use (default: `ollama/qwen3:14b`) |
| `OLLAMA_BASE_URL` | No | Override Ollama URL (default: `http://ollama:11434`) |

---

## Common Commands

```bash
# Start
docker compose up -d

# Stop
docker compose down

# Restart
docker compose restart

# View logs
docker compose logs -f            # all containers
docker compose logs -f openclaw   # gateway only
docker compose logs -f ollama     # Ollama only

# Check status
docker compose ps

# Rebuild after config changes
docker compose build --no-cache openclaw && docker compose up -d
```

---

## WhatsApp Integration

After the web UI is working:

```bash
docker exec -it openclaw-gateway openclaw channels login
```

Scan the QR code with WhatsApp on your phone. Once linked, you can message your assistant directly from WhatsApp.

---

## Switching Models

```bash
# List downloaded models
docker exec openclaw-ollama ollama list

# Pull a new model
docker exec openclaw-ollama ollama pull qwen3:8b

# Set it as default (then restart)
docker exec openclaw-gateway openclaw models set ollama/qwen3:8b
docker compose restart openclaw
```

---

## Volumes

| Volume | Contents |
|--------|----------|
| `ollama-data` | Downloaded LLM model files (~9 GB for qwen3:14b) |
| `openclaw-data` | Config, sessions, memory, canvas |
| `caddy-data` | TLS certificates |
| `caddy-config` | Caddy runtime config |

Reset OpenClaw state (keeps models):
```bash
docker compose down
docker volume rm openclaw_openclaw-data
docker compose up -d
```

Reset everything including models:
```bash
docker compose down
docker volume rm openclaw_ollama-data openclaw_openclaw-data openclaw_caddy-data openclaw_caddy-config
docker compose up -d
```

> After resetting `caddy-data`, re-export and re-install the root certificate in Windows.

---

## Troubleshooting

### "pairing required" in browser

```bash
openclaw-approve
```

Then refresh the browser.

### "origin not allowed"

Ensure you are using `https://` (not `http://`) and the Caddy cert is trusted in Windows.

### "control ui requires device identity"

Use `https://localhost:18790` — the browser must be in a secure context.

### ERR_CONNECTION_REFUSED on localhost:18790

Run the Windows port proxy commands in the **Quick Start** section above.

### ERR_SSL_PROTOCOL_ERROR

The Caddy root CA is not trusted. Re-export and re-install the certificate (Step 1 above), then fully restart Chrome.

### Gateway crashing (exit code 1)

```bash
docker compose logs openclaw | tail -30
```

### Ollama model not loading

```bash
docker exec openclaw-ollama ollama list
# If qwen3:14b is missing, pull it manually:
docker exec openclaw-ollama ollama pull qwen3:14b
```

---

## Project Structure

```
OpenClaw/
├── docker-compose.yml       # Orchestrates all containers
├── Caddyfile                # HTTPS reverse proxy config
├── .env.example             # Token template (copy to .env)
├── install-tools.sh         # Installs helper scripts to ~/.local/bin
├── openclaw-approve         # Approves browser device pairing requests
└── openclaw/
    ├── Dockerfile           # Node 22 + openclaw npm package
    └── entrypoint.sh        # Auto-configures openclaw on start
```

---

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines.

If this project saved you time, please give it a star — it helps others find it.

---

## License

MIT — see [License](./License)
