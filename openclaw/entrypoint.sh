#!/bin/sh
set -e

OLLAMA_URL="${OLLAMA_BASE_URL:-http://ollama:11434}"
MODEL="${OPENCLAW_MODEL:-ollama/qwen3:14b}"
TOKEN="${OPENCLAW_GATEWAY_TOKEN:-changeme}"
MODEL_NAME="${MODEL#ollama/}"
AGENT_DIR="${HOME}/.openclaw/agents/main/agent"

# ── 1. Wait for Ollama ───────────────────────────────────────────────────────
echo "[openclaw] Waiting for Ollama at $OLLAMA_URL ..."
until curl -sf "$OLLAMA_URL/api/tags" > /dev/null 2>&1; do
  sleep 3
done
echo "[openclaw] Ollama is ready."

# ── 2. Wait for the model to be pulled ──────────────────────────────────────
echo "[openclaw] Waiting for model $MODEL_NAME to be available ..."
until curl -sf "$OLLAMA_URL/api/show" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$MODEL_NAME\"}" > /dev/null 2>&1; do
  echo "[openclaw]   ... still pulling $MODEL_NAME, waiting 15s"
  sleep 15
done
echo "[openclaw] Model $MODEL_NAME is ready."

# ── 3. First-time openclaw config ────────────────────────────────────────────
if [ ! -f "${HOME}/.openclaw/openclaw.json" ]; then
  echo "[openclaw] First-time setup ..."
  openclaw config set gateway.mode local
  openclaw config set gateway.auth.token "$TOKEN"
fi

# ── 4. Write Ollama auth profile ─────────────────────────────────────────────
mkdir -p "$AGENT_DIR"
cat > "$AGENT_DIR/auth-profiles.json" << EOF
{
  "version": 1,
  "profiles": {
    "0": {
      "profileId": "ollama:local",
      "provider": "ollama",
      "type": "token",
      "token": "ollama-local"
    }
  },
  "usageStats": {}
}
EOF

# ── 5. Patch models.json with the container Ollama URL ───────────────────────
python3 - << PYEOF
import json, os

models_file = os.path.join(os.path.expanduser("$AGENT_DIR"), "models.json")
try:
    with open(models_file) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}

ollama = data.setdefault("providers", {}).setdefault("ollama", {})
ollama["baseUrl"] = "$OLLAMA_URL"
ollama["api"]    = "ollama"
ollama["apiKey"] = "ollama-local"

with open(models_file, "w") as f:
    json.dump(data, f, indent=2)

print("[openclaw] Ollama baseUrl set to $OLLAMA_URL")
PYEOF

# ── 6. Set default model ─────────────────────────────────────────────────────
openclaw models set "$MODEL" 2>/dev/null || true

# ── 7. Start gateway (bind to all interfaces so Docker port-mapping works) ───
echo "[openclaw] Starting gateway — model: $MODEL  bind: lan  port: 18789"
exec openclaw gateway run --bind lan --port 18789
