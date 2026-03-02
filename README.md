# OpenClaw — Containerised Setup

Personal AI assistant running on a local GPU via Ollama, accessible from a browser or WhatsApp.

## Architecture

```
┌─────────────────────────────────────────────┐
│  Docker (WSL2)                              │
│                                             │
│  ┌──────────────┐     ┌──────────────────┐  │
│  │ openclaw-    │────▶│ openclaw-ollama  │  │
│  │ gateway      │     │ (qwen3:14b)      │  │
│  │ :18789       │     │ RTX 5080 GPU     │  │
│  └──────────────┘     └──────────────────┘  │
└─────────────────────────────────────────────┘
         │
         ▼
  Windows browser / WhatsApp
```

## Prerequisites

- Docker with NVIDIA container runtime (`nvidia` runtime listed in `docker info`)
- WSL2 with NVIDIA drivers installed

## Configuration

Edit `.env` to set your gateway auth token:

```env
OPENCLAW_GATEWAY_TOKEN=your_token_here
```

To change the model, edit `docker-compose.yml` and update:

```yaml
OPENCLAW_MODEL=ollama/qwen3:14b
```

## Usage

### Start

```bash
docker compose up -d
```

On first start, `model-init` will pull `qwen3:14b` (~9 GB) into the ollama volume. The openclaw gateway waits until the model is ready before starting.

### Stop

```bash
docker compose down
```

### Restart

```bash
docker compose restart
```

### View logs

```bash
# All containers
docker compose logs -f

# Gateway only
docker compose logs -f openclaw

# Ollama only
docker compose logs -f ollama
```

### Check status

```bash
docker compose ps
```

### Rebuild after config changes

```bash
docker compose build --no-cache openclaw
docker compose up -d
```

## Accessing OpenClaw

### Windows browser

Get the WSL IP:

```bash
hostname -I | awk '{print $1}'
```

Then open in your browser:

```
http://<WSL-IP>:18789/#token=<OPENCLAW_GATEWAY_TOKEN>
```

Example:

```
http://172.25.75.125:18789/#token=b180cdc9ffdbbe6362df4446f29b7e9b1f9c21bcce4e9164
```

### WhatsApp (mobile)

After the web UI is working, link your WhatsApp account:

```bash
docker exec -it openclaw-gateway openclaw channels login
```

Follow the QR code prompts in the terminal to connect your WhatsApp account. Once linked, you can message the assistant directly from WhatsApp.

## Switching models

List models available in the running ollama container:

```bash
docker exec openclaw-ollama ollama list
```

Pull a new model:

```bash
docker exec openclaw-ollama ollama pull <model>
# e.g. docker exec openclaw-ollama ollama pull llama3.1:8b
```

Set it as the default in OpenClaw:

```bash
docker exec openclaw-gateway openclaw models set ollama/<model>
docker compose restart openclaw
```

## Volumes

| Volume          | Contents                          |
|-----------------|-----------------------------------|
| `ollama-data`   | Downloaded LLM model files        |
| `openclaw-data` | Config, sessions, memory, canvas  |

To reset OpenClaw state (keeps models):

```bash
docker compose down
docker volume rm openclaw_openclaw-data
docker compose up -d
```

To reset everything including models:

```bash
docker compose down
docker volume rm openclaw_ollama-data openclaw_openclaw-data
docker compose up -d
```
