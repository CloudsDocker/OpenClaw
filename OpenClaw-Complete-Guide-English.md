# OpenClaw Complete Guide: Build Your Own Private AI Assistant at Home

> **From Zero to Running: Step-by-Step Setup, Real Errors & Fixes, Telegram + GitHub + Live Weather Integration**

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Why Local AI?](#2-why-local-ai)
3. [Requirements](#3-requirements)
4. [System Architecture](#4-system-architecture)
5. [Installation — Step by Step](#5-installation--step-by-step)
   - [5.1 Clone the Repository](#51-clone-the-repository)
   - [5.2 Configure Environment Variables](#52-configure-environment-variables)
   - [5.3 Start the Containers](#53-start-the-containers)
   - [5.4 WSL2 + Windows Setup](#54-wsl2--windows-setup)
   - [5.5 Trust the HTTPS Certificate](#55-trust-the-https-certificate)
   - [5.6 Set Up Windows Port Proxy](#56-set-up-windows-port-proxy)
   - [5.7 Approve the Browser Device](#57-approve-the-browser-device)
6. [Telegram Integration](#6-telegram-integration)
7. [GitHub Integration](#7-github-integration)
8. [Live Weather Integration](#8-live-weather-integration)
9. [Common Errors & Fixes](#9-common-errors--fixes)
10. [Model Selection Guide](#10-model-selection-guide)
11. [Quick Reference](#11-quick-reference)
12. [Conclusion](#12-conclusion)

---

## 1. Introduction

Have you ever wanted a personal AI assistant that runs entirely on your own hardware — always available, completely private, and free to use forever? No cloud fees. No data leaving your machine. No censorship.

This guide walks you through every step to build exactly that, using **OpenClaw + Ollama** on a Windows PC with WSL2. OpenClaw provides the chat interface and tool integrations; Ollama runs open-source large language models locally on your NVIDIA GPU.

This is not just an installation guide — it is a **battle-tested error log**. Every real problem I hit during setup is documented here with its root cause and exact fix. By the end, you will understand *why* each step works, not just *what* to type.

What you will have when done:

- A private AI assistant accessible from your browser
- A Telegram bot so you can chat from your phone anywhere
- GitHub integration — create and review PRs just by asking
- Real-time weather via API (not AI guesses)
- GPU-accelerated inference with `qwen3:14b`

---

## 2. Why Local AI?

Before diving in, here is why this is worth the effort:

| Aspect | Cloud AI (e.g. ChatGPT) | Local AI (this setup) |
|--------|--------------------------|----------------------|
| **Privacy** | ❌ Data sent to servers | ✅ Data never leaves your PC |
| **Cost** | ❌ Monthly subscription | ✅ Free forever after setup |
| **Internet** | ❌ Requires connection | ✅ Works offline |
| **Speed** | ✅ Fast (server power) | ✅ Fast (your GPU) |
| **Customization** | ❌ Platform-limited | ✅ Fully customizable |
| **Model choice** | ❌ Only what they offer | ✅ Hundreds of open-source models |
| **Tool integration** | Partial | ✅ GitHub, Telegram, weather APIs, etc. |
| **Censorship** | ❌ Content filters | ✅ None |

> **The core idea:** Your AI, your rules. One setup investment, permanent use.

---

## 3. Requirements

### Hardware

| Component | Minimum | Recommended | Notes |
|-----------|---------|-------------|-------|
| OS | Windows 10 | Windows 11 | Better WSL2 support |
| GPU | NVIDIA RTX 3070 (8 GB VRAM) | RTX 4080/5080 (16 GB+) | CUDA required |
| RAM | 16 GB | 32 GB | Models load into RAM too |
| Disk | 20 GB free | 50 GB free | qwen3:14b needs ~9 GB |
| Network | Broadband | 100 Mbps+ | First pull is ~9 GB |

### Software

| Software | Version | Purpose | Where to Get |
|----------|---------|---------|--------------|
| Windows | 10 / 11 | Host OS | Already have it |
| WSL2 | 2.x | Linux subsystem for Docker | `wsl --install` |
| Ubuntu (WSL2) | 22.04 LTS | Linux distro | Microsoft Store (free) |
| Docker Desktop | 4.x+ | Container runtime | docker.com |
| NVIDIA Driver | 525+ | GPU driver | nvidia.com |
| NVIDIA Container Toolkit | Latest | Docker GPU passthrough | docs.nvidia.com |
| Git | 2.x+ | Clone the project | git-scm.com |

> **Critical check before you start:**
> ```bash
> docker info | grep -i nvidia
> # Expected output contains: Runtimes: ... nvidia ...
> ```
> If nothing shows up, install NVIDIA Container Toolkit first. Without it, the model runs on CPU — extremely slow.

---

## 4. System Architecture

The system is four Docker containers, each with a single clear responsibility, communicating over a private internal network and exposing only one HTTPS port to the outside world.

```
┌─────────────────────────── Docker Network: openclaw-net ───────────────────────────┐
│                                                                                     │
│  ┌──────────────────┐    ┌─────────────────────┐    ┌──────────────────────────┐   │
│  │  openclaw-ollama │───▶│  openclaw-gateway   │───▶│  openclaw-caddy          │   │
│  │                  │    │                     │    │  (HTTPS Reverse Proxy)   │   │
│  │  • Runs the LLM  │    │  • Chat UI          │    │  Port: 18790 (external)  │   │
│  │  • NVIDIA GPU    │    │  • Tool calling     │    │  Auto TLS certificate    │   │
│  │  • qwen3:14b     │    │  • Telegram bot     │    │                          │   │
│  │  Port: 11434     │    │  • GitHub API       │    └──────────────┬───────────┘   │
│  └──────────────────┘    │  Port: 18789        │                   │               │
│                           └─────────────────────┘                   │               │
│  ┌──────────────────┐                                               │               │
│  │  model-init      │                                               │               │
│  │  (one-shot)      │                                               │               │
│  │  Pulls model,    │                                               │               │
│  │  then exits      │                                               │               │
│  └──────────────────┘                                               │               │
└─────────────────────────────────────────────────────────────────────│───────────────┘
                                                                       │
                                                                       ▼
                              ┌──────────────────────────────────────────────┐
                              │  External Access                             │
                              │  • Browser: https://localhost:18790          │
                              │  • Phone: Telegram app (anywhere)            │
                              └──────────────────────────────────────────────┘
```

| Container | Image | Role | Port |
|-----------|-------|------|------|
| `openclaw-ollama` | `ollama/ollama:latest` | Runs LLM on GPU | 11434 (internal) |
| `openclaw-model-init` | `ollama/ollama:latest` | Pulls model on first run, then exits | None |
| `openclaw-gateway` | Custom build | Chat UI + tool engine | 18789 (internal) |
| `openclaw-caddy` | `caddy:latest` | HTTPS reverse proxy, auto TLS | **18790 (external)** |

---

## 5. Installation — Step by Step

### 5.1 Clone the Repository

Open your WSL2 terminal (search "Ubuntu" in the Windows Start menu) and run:

```bash
# Go to your preferred directory
cd ~

# Clone the project
git clone https://github.com/CloudsDocker/OpenClaw.git
cd OpenClaw

# Verify the structure
ls -la
```

You should see:

```
OpenClaw/
├── docker-compose.yml       # Orchestrates all containers
├── Caddyfile                # HTTPS reverse proxy config
├── .env.example             # Environment variable template
├── install-tools.sh         # Installs helper scripts
├── openclaw-approve         # Approves browser device pairing
└── openclaw/
    ├── Dockerfile           # Custom image build config
    └── entrypoint.sh        # Auto-configures OpenClaw on startup
```

---

### 5.2 Configure Environment Variables

This is the most important step. The `.env` file controls authentication, integrations, and model selection.

```bash
# Copy the template
cp .env.example .env

# Edit it
nano .env
```

Here is what each variable does:

```bash
# ──────────────────────────────────────────────────────────────
# REQUIRED
# ──────────────────────────────────────────────────────────────

# Gateway authentication token (used for browser login)
# Generate one with: openssl rand -hex 24
OPENCLAW_GATEWAY_TOKEN=your_strong_random_token_here

# ──────────────────────────────────────────────────────────────
# OPTIONAL: AI Model
# ──────────────────────────────────────────────────────────────
# qwen3:14b-fast = faster, less VRAM pressure (recommended default)
OPENCLAW_MODEL=ollama/qwen3:14b-fast

# ──────────────────────────────────────────────────────────────
# OPTIONAL: Telegram Bot
# ──────────────────────────────────────────────────────────────
# Get from @BotFather on Telegram
TELEGRAM_BOT_TOKEN=123456789:ABCdef_your_bot_token
# Your Telegram user ID (get from @userinfobot)
TELEGRAM_ALLOWED_USER_ID=987654321

# ──────────────────────────────────────────────────────────────
# OPTIONAL: GitHub Integration
# ──────────────────────────────────────────────────────────────
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
GITHUB_REPO=yourusername/yourrepo
GITHUB_USERNAME=yourusername
GITHUB_BASE_BRANCH=master

# ──────────────────────────────────────────────────────────────
# OPTIONAL: Brave Web Search
# ──────────────────────────────────────────────────────────────
BRAVE_API_KEY=BSAxxx...
```

> **Generate a secure token:**
> ```bash
> openssl rand -hex 24
> # Example output: a3f7b2c9d1e4f8a0b5c6d7e8f9a0b1c2
> ```
> Copy the output directly into `OPENCLAW_GATEWAY_TOKEN=` with no quotes.

---

### 5.3 Start the Containers

```bash
# Start all services in the background
docker compose up -d

# Watch startup logs in real time (recommended — open a second terminal)
docker compose logs -f openclaw

# Check container status
docker compose ps
```

When you see this, the system is fully ready:

```
[openclaw] Ollama is ready.
[openclaw] Model qwen3:14b is ready.
[openclaw] TOOLS.md written with GitHub access config
[openclaw] Registered 2 Ollama model(s): ['qwen3:14b', 'qwen3:14b-fast']
[openclaw] Starting gateway — model: ollama/qwen3:14b-fast  bind: lan  port: 18789
listening on ws://0.0.0.0:18789
```

> **⚠️ First start takes time**
>
> The `model-init` container downloads ~9 GB on the first run. This can take 10–60 minutes depending on your internet speed.
>
> Watch the download progress: `docker compose logs -f model-init`
>
> The container will exit on its own when done — this is normal.

---

### 5.4 WSL2 + Windows Setup

If you run Docker via WSL2 on Windows, extra network configuration is required. WSL2 has its own private network namespace with a separate IP (e.g. `172.x.x.x`) — your Windows browser cannot reach it directly.

```
Windows Browser          Windows Network Layer         WSL2 Network (Docker)
(Chrome/Edge)            (portproxy forwarding)        (containers)
     │                          │                            │
     │  https://localhost:18790 │   netsh portproxy          │
     │ ────────────────────────▶│ ──────────────────────────▶│ 172.x.x.x:18790
     │                          │                            │ openclaw-caddy
     │
     Problem: browser hits Windows localhost, but service is in WSL2 (172.x.x.x)
     Solution: Windows portproxy bridges the gap
```

The fix is a one-time Windows port proxy setup (see 5.6), plus trusting the HTTPS certificate (see 5.5).

---

### 5.5 Trust the HTTPS Certificate

Caddy auto-generates a local root CA certificate to issue HTTPS for localhost. Windows and Chrome do not trust unknown CAs by default — you must import it manually.

```bash
# Export the certificate from the container to your Windows filesystem
docker exec openclaw-caddy cat /data/caddy/pki/authorities/local/root.crt \
  > /mnt/c/Users/Public/caddy-root.crt

# Verify it was created
ls -lh /mnt/c/Users/Public/caddy-root.crt
```

Then import it in Windows:

1. Press `Win + R`, type `certmgr.msc`, press Enter
2. Expand **Trusted Root Certification Authorities** → click **Certificates**
3. Right-click the panel → **All Tasks** → **Import**
4. Browse to `C:\Users\Public\caddy-root.crt`
5. Place in **Trusted Root Certification Authorities**
6. **Fully restart Chrome** — close every window, reopen

> **If you ever reset the `caddy-data` Docker volume**, repeat this entire step — a new certificate is generated each time.

---

### 5.6 Set Up Windows Port Proxy

Open **PowerShell as Administrator** (right-click Start → "Windows PowerShell (Admin)"):

```powershell
# Step 1: Get your current WSL2 IP (run this in WSL2 terminal first)
# hostname -I | awk '{print $1}'
# Example output: 172.x.x.x

# Step 2: Set up the port proxy (replace 172.x.x.x with your actual IP)
netsh interface portproxy add v4tov4 listenport=18790 listenaddress=127.0.0.1 connectport=18790 connectaddress=172.x.x.x

netsh interface portproxy add v6tov4 listenport=18790 listenaddress=::1 connectport=18790 connectaddress=172.x.x.x

# Verify
netsh interface portproxy show all
```

> **⚠️ WSL2 IP changes on every reboot!**
>
> You need to re-run these commands after every reboot. Save this as a startup script:
>
> ```powershell
> # update-wsl-proxy.ps1
> $ip = (wsl hostname -I).Trim().Split(" ")[0]
> netsh interface portproxy delete v4tov4 listenport=18790 listenaddress=127.0.0.1
> netsh interface portproxy add v4tov4 listenport=18790 listenaddress=127.0.0.1 connectport=18790 connectaddress=$ip
> Write-Host "WSL2 proxy updated: $ip"
> ```

---

### 5.7 Approve the Browser Device

The first time your browser connects, OpenClaw requires device approval. This is a one-time security step.

```bash
# Install the helper script (one-time only)
bash install-tools.sh

# Open the browser first (to trigger the pairing request):
# https://localhost:18790/#token=<your_OPENCLAW_GATEWAY_TOKEN>

# Then run the approval command:
openclaw-approve

# Expected output:
# Approving xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx ...
# Approved <device-id>

# Refresh the browser — you should now see the chat interface
```

> **✅ Success!** If you see the OpenClaw chat interface, your private AI assistant is live.

---

## 6. Telegram Integration

Telegram integration lets you chat with your AI from your phone — anywhere, anytime, like texting a friend.

### Setup Steps

1. Open Telegram → search for **@BotFather** → send `/newbot`
2. Give your bot a name (e.g. "My AI Assistant") and a username ending in `bot`
3. BotFather gives you a token like: `123456789:ABCdef_GHIjkl...`
4. Search **@userinfobot** → send any message → it tells you your numeric user ID
5. Add both to your `.env` file, then rebuild:

```bash
# In .env:
TELEGRAM_BOT_TOKEN=123456789:ABCdef_your_real_token
TELEGRAM_ALLOWED_USER_ID=987654321

# Rebuild the gateway:
docker compose build --no-cache openclaw
docker compose up -d openclaw

# Test: find your bot in Telegram, send "hello"
```

### How it works

```
Your Phone              Telegram Servers          OpenClaw (your home PC)
(Telegram App)          (telegram.org)            (openclaw-gateway)
     │                        │                         │
     │  "What's the weather?" │   HTTPS long-polling    │
     │ ──────────────────────▶│ ───────────────────────▶│
     │                        │                         │  calls weather API
     │                        │                         │  (Open-Meteo)
     │  "Tomorrow: 24–31°C,   │   returns AI reply      │
     │   sunny, UV 9"         │ ◀───────────────────────│
     │ ◀──────────────────────│                         │
```

> **Security note:** `TELEGRAM_ALLOWED_USER_ID` is a whitelist — only your numeric user ID can talk to the bot. Even if someone finds your bot's username, they cannot interact with it.

---

## 7. GitHub Integration

With GitHub integration, you can manage pull requests and branches through natural conversation — no browser, no Git commands to memorize.

### Get a GitHub Personal Access Token

1. Go to GitHub.com → click your avatar → **Settings**
2. Scroll to bottom: **Developer settings** → **Personal access tokens** → **Tokens (classic)**
3. Click **Generate new token (classic)**
4. Select scopes: **repo** (all sub-options)
5. Generate and **copy immediately** — you cannot view it again after leaving the page

```bash
# In .env:
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
GITHUB_REPO=yourusername/yourrepo
GITHUB_USERNAME=yourusername
GITHUB_BASE_BRANCH=master

# Rebuild:
docker compose build --no-cache openclaw
docker compose up -d openclaw
```

### What you can now ask your AI

```
You:  "Show me my open PRs"
AI:   Immediately runs Python code → lists all your open pull requests with links

You:  "Create a PR from feature/login-fix to master"
AI:   Automatically creates the PR → returns the PR number and link

You:  "What branch did I commit to most recently?"
AI:   Queries all branches by commit date → returns the newest one
```

---

## 8. Live Weather Integration

### The Problem: AI Hallucinates Weather Data

Without a weather tool, asking your AI "what's the weather tomorrow?" produces **completely fabricated data**. The AI has no access to real-time information — it predicts text based on training patterns. This is called **hallucination**.

> **Real example from this setup:**
>
> User: *"What's the weather like tomorrow?"*
>
> AI (without fix): *"Tomorrow: partly cloudy, high 18°C, low 12°C, NE winds..."*
>
> **Actual weather: 32°C, sunny, summer.** The AI's answer was entirely made up.

### The Hidden Trap: `entrypoint.sh` Overwrites Your Config

You might think: just add a weather section to `workspace/TOOLS.md`. But there is a critical gotcha:

**`entrypoint.sh` regenerates and overwrites `TOOLS.md` every time the container starts.**

```
Every container start:

  entrypoint.sh
       │
       │  python3 writes (OVERWRITES)
       ▼
  ~/.openclaw/workspace/TOOLS.md   ← this is what the AI reads

  workspace/TOOLS.md (project dir) ──✗── only used for the very first volume creation

  Result: editing workspace/TOOLS.md directly has NO effect after first run!
  Correct approach: edit the Python content string inside entrypoint.sh.
```

### The Fix

Open `openclaw/entrypoint.sh` and find the Python content string (`content = """..."""`). Add your weather tool section **before the closing `"""`**:

```python
## Weather

**Your location:** your city, your country
**Coordinates:** your latitude, your longitude

**RULE: NEVER guess weather. Always fetch it using exec python3.**

When asked about weather — exec this immediately:

```python
import urllib.request, json
lat, lon = YOUR_LATITUDE, YOUR_LONGITUDE  # replace with your coordinates
url = (
    "https://api.open-meteo.com/v1/forecast"
    f"?latitude={lat}&longitude={lon}"
    "&daily=weather_code,temperature_2m_max,temperature_2m_min,"
    "precipitation_sum,wind_speed_10m_max,uv_index_max"
    "&current=temperature_2m,weather_code,wind_speed_10m,relative_humidity_2m"
    "&timezone=YOUR_TIMEZONE&forecast_days=7"
)
data = json.load(urllib.request.urlopen(url))
wmo = {0:"Clear sky",1:"Mainly clear",2:"Partly cloudy",3:"Overcast",
       61:"Rain",63:"Heavy rain",80:"Showers",81:"Heavy showers",95:"Thunderstorm"}
cur = data["current"]
print(f"NOW: {cur['temperature_2m']}°C, {wmo.get(cur['weather_code'],'?')}, "
      f"wind {cur['wind_speed_10m']} km/h, humidity {cur['relative_humidity_2m']}%")
for i, date in enumerate(data["daily"]["time"]):
    hi = data["daily"]["temperature_2m_max"][i]
    lo = data["daily"]["temperature_2m_min"][i]
    rain = data["daily"]["precipitation_sum"][i]
    label = ["Today","Tomorrow"][i] if i < 2 else date
    print(f"{label}: {lo}–{hi}°C, {wmo.get(data['daily']['weather_code'][i],'?')}, rain {rain}mm")
```
```

**How to find your coordinates:**

1. Open maps.google.com and search for your area
2. Right-click your location → "What's here?"
3. The coordinates appear at the bottom: `latitude, longitude` (e.g. `-33.8, 151.2`)

**How to find your timezone string:**

- Australia/Sydney, America/New_York, Europe/London, Asia/Shanghai, etc.
- Full list: [en.wikipedia.org/wiki/List_of_tz_database_time_zones](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones)

Then rebuild:

```bash
docker compose build --no-cache openclaw
docker compose up -d openclaw
```

> **After the fix:**
>
> User: *"What's the weather tomorrow?"*
>
> AI: *(immediately fetches Open-Meteo API)*
>
> AI: *"Tomorrow: 21–31°C, Clear sky, 0mm rain, wind 12 km/h, UV index 9"*
>
> **Open-Meteo API is completely free — no sign-up, no API key required.**

---

## 9. Common Errors & Fixes

All ten errors below are real — encountered and solved during this actual setup.

### Error Quick Reference

| # | Error | Root Cause | Severity |
|---|-------|-----------|----------|
| E1 | `ERR_CONNECTION_REFUSED` on localhost:18790 | Windows portproxy not configured | 🔴 Blocker |
| E2 | `ERR_SSL_PROTOCOL_ERROR` | Caddy root cert not trusted in Windows | 🔴 Blocker |
| E3 | "pairing required" / "origin not allowed" | Device not approved or using http:// | 🔴 Blocker |
| E4 | GPU not detected / CUDA error | NVIDIA Container Runtime not set up | 🔴 Blocker |
| E5 | Model extremely slow (< 2 tokens/sec) | GPU init failed, fell back to CPU | 🟡 Performance |
| E6 | AI gives wrong weather data | No weather tool, AI hallucinates | 🟡 Correctness |
| E7 | Changes to TOOLS.md ignored | `entrypoint.sh` overwrites it on every start | 🟡 Config trap |
| E8 | exec tool unavailable in Telegram | Telegram channel not granted exec permission | 🟡 Feature |
| E9 | GitHub API 401 Unauthorized | Token invalid, expired, or wrong scopes | 🟡 Feature |
| E10 | Browser fails to connect after reboot | WSL2 gets a new IP on every restart | 🟢 Maintenance |

---

### E1: ERR_CONNECTION_REFUSED (localhost:18790)

**Symptom:** Chrome shows `ERR_CONNECTION_REFUSED` when opening `https://localhost:18790`

**Root Cause:**
Docker runs inside WSL2's network namespace with IP `172.x.x.x`. Your Windows browser connects to Windows `localhost`, which is a completely different network. Without a port proxy, the two cannot communicate.

**Fix:**

```bash
# In WSL2 terminal — get your current IP:
hostname -I | awk '{print $1}'
# Example: 172.x.x.x

# In PowerShell (Admin) — set up the proxy (replace IP):
netsh interface portproxy add v4tov4 listenport=18790 listenaddress=127.0.0.1 connectport=18790 connectaddress=172.x.x.x
netsh interface portproxy add v6tov4 listenport=18790 listenaddress=::1 connectport=18790 connectaddress=172.x.x.x

# Refresh the browser
```

---

### E2: ERR_SSL_PROTOCOL_ERROR

**Symptom:** Chrome shows `ERR_SSL_PROTOCOL_ERROR` or `NET::ERR_CERT_AUTHORITY_INVALID`

**Root Cause:**
Caddy uses a self-signed local CA. Windows and Chrome do not trust unknown certificate authorities — the connection is rejected.

**Fix:**

```bash
# Export the Caddy root certificate to Windows
docker exec openclaw-caddy cat /data/caddy/pki/authorities/local/root.crt \
  > /mnt/c/Users/Public/caddy-root.crt
```

Then in Windows:

1. `Win + R` → type `certmgr.msc` → Enter
2. Expand **Trusted Root Certification Authorities** → **Certificates**
3. Right-click → **All Tasks** → **Import**
4. Select `C:\Users\Public\caddy-root.crt`
5. Store location: **Trusted Root Certification Authorities**
6. **Fully restart Chrome** (close all windows)

---

### E3: "Pairing Required" / "Origin Not Allowed"

**Symptom:** OpenClaw shows "Device pairing required" or "Origin not allowed"

**Root Cause:**
- *Pairing required*: Every new browser must be approved once — this is a security feature.
- *Origin not allowed*: You are using `http://` instead of `https://`, or the browser is not in a secure context.

**Fix:**

```bash
# Fix "pairing required":
openclaw-approve
# Then refresh the browser

# Fix "origin not allowed":
# Make sure your URL starts with https://
# Correct: https://localhost:18790/#token=<your_token>
```

---

### E4: GPU Not Detected / CUDA Error

**Symptom:** `docker compose logs ollama` shows `cuda: driver version mismatch` or `no GPU found`

**Root Cause:**
NVIDIA Container Runtime is not installed or not connected to Docker. Without it, Docker containers cannot access the GPU.

**Fix:**

```bash
# Check if Docker sees the GPU
docker info | grep -i nvidia
# Expected: Runtimes: ... nvidia ...

# Test direct GPU access
docker run --rm --gpus all nvidia/cuda:12.0-base-ubuntu22.04 nvidia-smi
# Should print your GPU details

# If not working:
# 1. Install NVIDIA Container Toolkit (see docs.nvidia.com)
# 2. Docker Desktop → Settings → Resources → WSL Integration → enable your Ubuntu distro
# 3. Restart Docker Desktop
```

---

### E5: Model Extremely Slow (CPU Mode)

**Symptom:** Responses trickle out at 1–2 words per second — not the smooth streaming you expect

**Root Cause:**
If GPU initialization fails, Ollama silently falls back to CPU inference. A 14B model on CPU generates ~1–3 tokens/sec; on GPU it should be 30–60 tokens/sec.

**Fix:**

```bash
# Check if Ollama is actually using the GPU
docker compose logs ollama | grep -E "gpu|cuda|GPU|CUDA"
# Expect: "CUDA: 1" or "GPU layers: 33/33"

# Watch GPU utilization in real time (in WSL2)
nvidia-smi -l 1
# If GPU stays at ~0% while AI generates — it's running on CPU

# Resolution: fix NVIDIA Container Runtime (see E4), then restart
docker compose restart ollama
```

---

### E6: AI Gives Wrong Weather Data (Hallucination)

**Symptom:** AI states weather confidently but the temperature, conditions, and season are completely wrong

**Root Cause:**
The AI has no real-time data access. Without a weather tool, it predicts plausible-sounding weather from training data patterns — this is *hallucination*. The answer can sound convincing while being entirely fabricated.

**Fix:** See [Section 8](#8-live-weather-integration) for the full solution.

---

### E7: Changes to TOOLS.md Are Ignored

**Symptom:** You edit `workspace/TOOLS.md`, restart the container, but AI behaviour does not change

**Root Cause:**
`entrypoint.sh` runs a Python script that regenerates and overwrites `TOOLS.md` on every container start. The `workspace/TOOLS.md` in the project directory is only used as a seed when the Docker volume is first created.

**Fix:**

```bash
# ❌ WRONG — this gets overwritten on every restart:
vim workspace/TOOLS.md

# ✅ CORRECT — edit the Python content string in entrypoint.sh:
vim openclaw/entrypoint.sh
# Find:  content = """..."""
# Add your content BEFORE the closing """

# Then rebuild for changes to take effect:
docker compose build --no-cache openclaw
docker compose up -d openclaw
```

---

### E8: exec Tool Unavailable in Telegram

**Symptom:** Asking the AI to run code via Telegram, it says "I don't have an exec tool" or just describes steps without executing

**Root Cause:**
OpenClaw manages tool permissions per channel. The Telegram DM channel does not have `exec` enabled by default — it must be explicitly granted in the configuration.

**Fix:**

Ensure `entrypoint.sh` includes the following configurations:

```bash
# Global exec tool setup
openclaw config set tools.exec.security allowlist
openclaw config set tools.exec.safeBins '["curl","python3"]'
openclaw config set tools.exec.ask off
openclaw config set tools.exec.host gateway

# In the Telegram DM system prompt section:
# dm_direct["tools"] = {"alsoAllow": ["exec"]}
```

Then rebuild: `docker compose build --no-cache openclaw && docker compose up -d openclaw`

---

### E9: GitHub API 401 Unauthorized

**Symptom:** AI returns `401 Unauthorized` or `{"message": "Bad credentials"}` when doing GitHub operations

**Root Cause:**
The Personal Access Token is invalid (wrong format, extra whitespace), has expired, or was not granted `repo` scope.

**Fix:**

```bash
# Check the token in your .env (should start with ghp_, no spaces)
grep GITHUB_TOKEN .env

# Test the token directly
curl -H "Authorization: token YOUR_TOKEN" https://api.github.com/user
# Should return your user JSON, not a 401

# If expired, regenerate:
# GitHub.com → Settings → Developer settings → Personal access tokens → Generate new
# Required scopes: repo (all sub-options)
```

---

### E10: Browser Fails to Connect After Reboot

**Symptom:** After restarting your PC, `https://localhost:18790` gives `ERR_CONNECTION_REFUSED` again

**Root Cause:**
WSL2 uses dynamic IP assignment — it gets a new IP address every time it restarts. Your portproxy rules still point to the old IP and no longer work.

**Fix:**

```bash
# Get the new WSL2 IP (in WSL2 terminal)
NEW_IP=$(hostname -I | awk '{print $1}')
echo "New IP: $NEW_IP"
```

```powershell
# In PowerShell (Admin) — update the proxy rules:
netsh interface portproxy delete v4tov4 listenport=18790 listenaddress=127.0.0.1
netsh interface portproxy delete v6tov4 listenport=18790 listenaddress=::1
netsh interface portproxy add v4tov4 listenport=18790 listenaddress=127.0.0.1 connectport=18790 connectaddress=<new-ip>
netsh interface portproxy add v6tov4 listenport=18790 listenaddress=::1 connectport=18790 connectaddress=<new-ip>
```

> **Automation tip:** Save the PowerShell block above as `update-wsl-proxy.ps1` and add it to Windows Task Scheduler to run at login. Or configure a static WSL2 IP in `%USERPROFILE%\.wslconfig`.

---

## 10. Model Selection Guide

Choose the model based on your GPU's VRAM and use case:

| Model | VRAM | Speed | Quality | Best For |
|-------|------|-------|---------|----------|
| `qwen3:14b-fast` | ~10 GB | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | Daily use, tool calling **(default, recommended)** |
| `qwen3:14b` | ~10 GB | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | Deep reasoning, complex code, long analysis |
| `qwen3:8b` | ~6 GB | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | Lower VRAM systems, quick answers |
| `llama3.1:latest` | ~5 GB | ⭐⭐⭐⭐ | ⭐⭐⭐ | English-heavy tasks, lightweight setup |
| `phi4` | ~9 GB | ⭐⭐⭐ | ⭐⭐⭐ | ⚠️ No tool calling — not recommended for this setup |

```bash
# Download a new model
docker exec openclaw-ollama ollama pull qwen3:8b

# Switch the active model
docker exec openclaw-gateway openclaw models set ollama/qwen3:8b
docker compose restart openclaw

# Or change OPENCLAW_MODEL in .env and restart:
docker compose up -d openclaw

# List downloaded models
docker exec openclaw-ollama ollama list
```

---

## 11. Quick Reference

```bash
# ─── Start / Stop / Restart ──────────────────────────────────────────────────
docker compose up -d                      # Start all services
docker compose down                       # Stop and remove containers
docker compose restart openclaw           # Restart only the AI gateway

# ─── Logs ────────────────────────────────────────────────────────────────────
docker compose logs -f                    # All containers, live
docker compose logs -f openclaw           # Gateway only, live
docker compose logs -f ollama             # Ollama only, live
docker compose logs --tail=50 openclaw    # Last 50 lines

# ─── Status ──────────────────────────────────────────────────────────────────
docker compose ps                         # Container status
docker exec openclaw-ollama ollama list   # Downloaded models
nvidia-smi                                # GPU status (in WSL2)

# ─── Rebuild After Config Change ──────────────────────────────────────────────
docker compose build --no-cache openclaw && docker compose up -d openclaw

# ─── Reset OpenClaw Data (keeps models) ──────────────────────────────────────
docker compose down
docker volume rm openclaw_openclaw-data
docker compose up -d

# ─── Full Reset (deletes everything including the 9 GB model) ─────────────────
docker compose down
docker volume rm openclaw_ollama-data openclaw_openclaw-data openclaw_caddy-data openclaw_caddy-config
docker compose up -d
# ⚠️ After full reset: re-export and re-import the Caddy certificate
```

---

## 12. Conclusion

After working through all of this, you now have a fully private, GPU-accelerated AI assistant running on your own hardware:

- ✅ **100% local** — your data never leaves your machine
- ✅ **GPU-accelerated** — `qwen3:14b` running fast on your NVIDIA card
- ✅ **Secure HTTPS** — Caddy manages certificates automatically
- ✅ **Mobile access** — Telegram bot, works anywhere from your phone
- ✅ **GitHub integration** — manage PRs through conversation
- ✅ **Real weather data** — Open-Meteo API, no more hallucinations
- ✅ **Free forever** — no subscriptions, no ongoing cost

The biggest takeaway is not just having the system — it is understanding *why* each piece works. Why WSL2 needs port proxying. Why `entrypoint.sh` overwrites config files. Why AI hallucinates without tools. This understanding lets you truly own and extend the setup.

**Future directions:** email monitoring, calendar reminders, smart home control, private document Q&A — the foundation you just built supports all of it.

---

If this guide helped you, please give the project a ⭐ star on GitHub and share it with others who want their own private AI assistant!

```
https://github.com/CloudsDocker/OpenClaw
```

---

*Version 1.0 · March 2026*
