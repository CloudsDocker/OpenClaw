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
# Always ensure auth mode and origin settings are applied
openclaw config set gateway.auth.mode token 2>/dev/null || true
openclaw config set gateway.controlUi.allowedOrigins '["https://localhost:18790","https://172.25.75.125:18790"]' 2>/dev/null || true

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

# ── 5. Patch models.json — register provider + all available models ──────────
python3 - << PYEOF
import json, os, urllib.request

models_file = os.path.join(os.path.expanduser("$AGENT_DIR"), "models.json")
try:
    with open(models_file) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}

# Fetch model list from Ollama
try:
    with urllib.request.urlopen("$OLLAMA_URL/api/tags", timeout=10) as r:
        tags = json.load(r).get("models", [])
except Exception as e:
    print(f"[openclaw] Warning: could not fetch Ollama model list: {e}")
    tags = []

model_entries = []
for m in tags:
    name = m.get("name", "")
    details = m.get("details", {})
    ctx = 32768  # safe default
    model_entries.append({
        "id":            name,
        "name":          name,
        "reasoning":     False,
        "input":         ["text"],
        "cost":          {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
        "contextWindow": ctx,
        "maxTokens":     8192,
    })

ollama = data.setdefault("providers", {}).setdefault("ollama", {})
ollama["baseUrl"] = "$OLLAMA_URL"
ollama["api"]    = "ollama"
ollama["apiKey"] = "ollama-local"
# Only overwrite models if we got a non-empty list; preserve existing entries on fetch failure
if model_entries:
    ollama["models"] = model_entries
elif not ollama.get("models"):
    ollama["models"] = []

with open(models_file, "w") as f:
    json.dump(data, f, indent=2)

print(f"[openclaw] Registered {len(model_entries)} Ollama model(s): {[m['id'] for m in model_entries]}")
PYEOF

# ── 6. Set default model ─────────────────────────────────────────────────────
openclaw models set "$MODEL" 2>/dev/null || true

# ── 7. Start background model-watcher — re-patches models.json if wiped ──────
# The gateway's auto-discovery can wipe models.json on startup; this loop
# restores it every 15 s whenever the models list becomes empty.
(
  MODELS_FILE="$AGENT_DIR/models.json"
  OLLAMA="$OLLAMA_URL"
  while true; do
    sleep 15
    python3 -c "
import json, urllib.request, sys
f = '$MODELS_FILE'
try:
    data = json.load(open(f))
except Exception:
    data = {}
ollama = data.get('providers', {}).get('ollama', {})
if ollama.get('models'):
    sys.exit(0)  # models already registered, nothing to do
try:
    tags = json.load(urllib.request.urlopen('$OLLAMA/api/tags', timeout=5)).get('models', [])
except Exception:
    sys.exit(0)
if not tags:
    sys.exit(0)
entries = [{'id':m['name'],'name':m['name'],'reasoning':False,'input':['text'],'cost':{'input':0,'output':0,'cacheRead':0,'cacheWrite':0},'contextWindow':32768,'maxTokens':8192} for m in tags]
data.setdefault('providers',{}).setdefault('ollama',{}).update({'baseUrl':'$OLLAMA','api':'ollama','apiKey':'ollama-local','models':entries})
json.dump(data, open(f,'w'), indent=2)
print('[openclaw] model-watcher: restored', [e['id'] for e in entries])
" 2>&1 || true
  done
) &

# ── 8. TCP proxy: localhost:11434 → ollama:11434 ──────────────────────────────
# The gateway's Ollama auto-discovery is hardcoded to http://localhost:11434.
# This proxy makes that address work without changing the gateway.
node -e "
const net = require('net');
const server = net.createServer(function(src) {
  const dst = net.connect(11434, 'ollama');
  src.pipe(dst); dst.pipe(src);
  src.on('error', function(){}); dst.on('error', function(){});
});
server.listen(11434, '127.0.0.1', function() {
  process.stdout.write('[openclaw] proxy: localhost:11434 -> ollama:11434\n');
});
// Keep running
setInterval(function(){}, 1 << 30);
" &

sleep 1

# ── 9. Start gateway (bind to all interfaces so Docker port-mapping works) ───
echo "[openclaw] Starting gateway — model: $MODEL  bind: lan  port: 18789"
exec openclaw gateway run --bind lan --port 18789
