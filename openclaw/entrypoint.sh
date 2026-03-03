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

# ── 3b. Exec tool — allow safe binaries the agent may call ───────────────────
openclaw config set tools.exec.security allowlist 2>/dev/null || true
openclaw config set tools.exec.safeBins '["curl","python3"]' 2>/dev/null || true
# Empty profiles = no flag restrictions; required or the binaries are silently ignored
openclaw config set tools.exec.safeBinProfiles.curl '{}' 2>/dev/null || true
openclaw config set tools.exec.safeBinProfiles.python3 '{}' 2>/dev/null || true
# Run exec in gateway process (not sandbox) and never ask for approval via channel
openclaw config set tools.exec.host gateway 2>/dev/null || true
openclaw config set tools.exec.ask off 2>/dev/null || true

# ── 3c. Web search (Brave) ────────────────────────────────────────────────────
if [ -n "$BRAVE_API_KEY" ]; then
  echo "[openclaw] Configuring Brave web search ..."
  openclaw config set tools.web.search.provider brave 2>/dev/null || true
  openclaw config set tools.web.search.apiKey "$BRAVE_API_KEY" 2>/dev/null || true
  echo "[openclaw] Web search enabled (Brave)"
else
  echo "[openclaw] BRAVE_API_KEY not set — web search disabled"
fi

# ── 4. Write Ollama auth profile ─────────────────────────────────────────────
mkdir -p "$AGENT_DIR"
WORKSPACE_DIR="${HOME}/.openclaw/workspace"
mkdir -p "$WORKSPACE_DIR"

# ── 4a. Write TOOLS.md — GitHub access + code templates for the agent ─────────
if [ -n "$GITHUB_TOKEN" ]; then
python3 - << PYEOF
import os
repo = os.environ['GITHUB_REPO']
user = os.environ['GITHUB_USERNAME']
base = os.environ.get('GITHUB_BASE_BRANCH', 'master')

content = """# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for specifics unique to this setup.

## GitHub

Full GitHub API access is configured. **When asked about GitHub PRs or branches: call exec with python3 immediately — never describe steps or ask the user to manually do anything.**

These env vars are available in exec python3:
- GITHUB_TOKEN: set (repo scope, SSO authorized)
- GITHUB_REPO: """ + repo + """
- GITHUB_USERNAME: """ + user + """
- GITHUB_BASE_BRANCH: """ + base + """

### List my open PRs — exec this immediately:

import os, urllib.request, json
h = {"Authorization": "token " + os.environ["GITHUB_TOKEN"], "Accept": "application/vnd.github+json"}
prs = json.load(urllib.request.urlopen(urllib.request.Request(
    "https://api.github.com/repos/" + os.environ["GITHUB_REPO"] + "/pulls?state=open&per_page=50", headers=h)))
mine = [p for p in prs if p["user"]["login"] == os.environ["GITHUB_USERNAME"]]
for p in mine:
    print("#" + str(p["number"]) + ": " + p["title"] + "  " + p["head"]["ref"] + "  " + p["html_url"])

### Find my latest branch (skip master/main/develop/staging) — exec this immediately:

import os, urllib.request, json
h = {"Authorization": "token " + os.environ["GITHUB_TOKEN"], "Accept": "application/vnd.github+json"}
bs = json.load(urllib.request.urlopen(urllib.request.Request(
    "https://api.github.com/repos/" + os.environ["GITHUB_REPO"] + "/branches?per_page=100", headers=h)))
skip = {"master", "main", "develop", "staging"}
results = []
for b in bs:
    if b["name"] in skip: continue
    c = json.load(urllib.request.urlopen(urllib.request.Request(
        "https://api.github.com/repos/" + os.environ["GITHUB_REPO"] + "/commits/" + b["commit"]["sha"], headers=h)))
    results.append((c["commit"]["committer"]["date"], b["name"]))
results.sort(reverse=True)
for d, n in results[:5]:
    print(d + " " + n)
"""

with open(os.path.expanduser("~/.openclaw/workspace/TOOLS.md"), "w") as f:
    f.write(content)
print("[openclaw] TOOLS.md written with GitHub access config")
PYEOF
fi
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
    # qwen3:14b-fast — smaller context, thinking disabled via providerOptions
    is_fast = name == "qwen3:14b-fast"
    entry = {
        "id":            name,
        "name":          name,
        "reasoning":     False,
        "input":         ["text"],
        "cost":          {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
        "contextWindow": 8192 if is_fast else 32768,
        "maxTokens":     4096 if is_fast else 8192,
    }
    if is_fast:
        entry["providerOptions"] = {"ollama": {"think": False}}
    model_entries.append(entry)

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

# ── 6b. Telegram channel ─────────────────────────────────────────────────────
if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
  echo "[openclaw] Configuring Telegram bot ..."
  openclaw channels add \
    --channel telegram \
    --token "$TELEGRAM_BOT_TOKEN" 2>/dev/null || true

  # Restrict to your Telegram user ID only (set allowFrom before dmPolicy)
  if [ -n "$TELEGRAM_ALLOWED_USER_ID" ]; then
    openclaw config set channels.telegram.allowFrom \
      "[\"$TELEGRAM_ALLOWED_USER_ID\"]" 2>/dev/null || true
    openclaw config set channels.telegram.dmPolicy allowlist 2>/dev/null || true
  fi
  echo "[openclaw] Telegram bot configured"
else
  echo "[openclaw] TELEGRAM_BOT_TOKEN not set — Telegram disabled"
fi

# ── 6c. GitHub PR directive — inject system prompt for Telegram DMs ──────────
if [ -n "$GITHUB_TOKEN" ]; then
  echo "[openclaw] Configuring GitHub PR agent directive ..."
  python3 - << PYEOF
import json, os

cfg_file = os.path.join(os.path.expanduser('~'), '.openclaw', 'openclaw.json')
try:
    with open(cfg_file) as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}

repo   = os.environ.get('GITHUB_REPO', 'unknown/repo')
user   = os.environ.get('GITHUB_USERNAME', 'unknown')
base   = os.environ.get('GITHUB_BASE_BRANCH', 'master')

directive = (
    "You are a personal dev assistant for " + user + ". "
    "CRITICAL RULE: You have the exec tool available. ALWAYS use exec to run python3 code to "
    "interact with GitHub. NEVER describe steps, NEVER list options, NEVER say tools are missing. "
    "Just run the code immediately and show results. "
    "\\n\\n"
    "GitHub environment variables (available via os.environ in exec python3):\\n"
    "  GITHUB_TOKEN  — API token (repo scope)\\n"
    "  GITHUB_REPO   — " + repo + "\\n"
    "  GITHUB_USERNAME — " + user + "\\n"
    "  GITHUB_BASE_BRANCH — " + base + "\\n"
    "GitHub REST API base: https://api.github.com\\n"
    "Always add header: Authorization: token <GITHUB_TOKEN>\\n"
    "NEVER print the token value.\\n"
    "\\n"
    "Common tasks — execute these immediately with exec python3:\\n"
    "\\n"
    "LIST MY PRs: GET /repos/" + repo + "/pulls?state=open&per_page=50 "
    "filtered by user.login==" + user + ". Show: PR number, title, branch, URL.\\n"
    "\\n"
    "FIND LATEST BRANCH: GET /repos/" + repo + "/branches?per_page=100 "
    "then for each branch GET /repos/" + repo + "/commits/<sha> to get committer date. "
    "Skip master/main/develop/staging. Pick newest by date.\\n"
    "\\n"
    "CREATE PR: POST /repos/" + repo + "/pulls "
    "body={head:<branch>, base:'" + base + "', title:<from commits>, body:<summary>}. "
    "After creating, compose team message: "
    "'Hi team, could you review PR #N? [title] — [one-line summary]. Link: <url>'\\n"
    "\\n"
    "LIST ALL BRANCHES: GET /repos/" + repo + "/branches?per_page=100"
)

# Write directive and remove any legacy 'dm' key (invalid schema key)
# Also explicitly allow exec tool in Telegram DM context
telegram = cfg.setdefault('channels', {}).setdefault('telegram', {})
telegram.pop('dm', None)
user_id = os.environ.get('TELEGRAM_ALLOWED_USER_ID', '*')
dm_direct = telegram.setdefault('direct', {}).setdefault(user_id, {})
dm_direct['systemPrompt'] = directive
dm_direct['tools'] = {'alsoAllow': ['exec']}

with open(cfg_file, 'w') as f:
    json.dump(cfg, f, indent=2)
print('[openclaw] GitHub PR directive written to openclaw.json')
PYEOF
else
  echo "[openclaw] GITHUB_TOKEN not set — GitHub PR workflow disabled"
fi

# ── 7. Set default model ─────────────────────────────────────────────────────
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
    tags = json.load(urllib.request.urlopen('$OLLAMA/api/tags', timeout=5)).get('models', [])
except Exception:
    sys.exit(0)
if not tags:
    sys.exit(0)
try:
    data = json.load(open(f))
except Exception:
    data = {}
# Build desired entries with providerOptions for qwen3:14b-fast
entries = []
for m in tags:
    n = m['name']
    fast = n == 'qwen3:14b-fast'
    e = {'id':n,'name':n,'reasoning':False,'input':['text'],'cost':{'input':0,'output':0,'cacheRead':0,'cacheWrite':0},'contextWindow':8192 if fast else 32768,'maxTokens':4096 if fast else 8192}
    if fast:
        e['providerOptions'] = {'ollama': {'think': False}}
    entries.append(e)
# Only write if something changed (avoid thrashing)
ollama = data.get('providers', {}).get('ollama', {})
existing = {m.get('id'): m for m in ollama.get('models', [])}
needs_update = any(existing.get(e['id'], {}).get('providerOptions') != e.get('providerOptions') or existing.get(e['id'], {}).get('contextWindow') != e.get('contextWindow') for e in entries) or not ollama.get('models')
if not needs_update:
    sys.exit(0)
data.setdefault('providers',{}).setdefault('ollama',{}).update({'baseUrl':'$OLLAMA','api':'ollama','apiKey':'ollama-local','models':entries})
json.dump(data, open(f,'w'), indent=2)
print('[openclaw] model-watcher: patched', [e['id'] for e in entries])
" 2>&1 || true
  done
) &

# ── 8. HTTP proxy: localhost:11434 → ollama:11434 ────────────────────────────
# The gateway's Ollama auto-discovery is hardcoded to http://localhost:11434.
# This HTTP proxy fixes that AND injects think:false for *-fast models so
# qwen3 does not generate internal reasoning tokens (44x speed improvement).
node -e "
const http = require('http');
const server = http.createServer(function(req, res) {
  var chunks = [];
  req.on('data', function(c) { chunks.push(c); });
  req.on('end', function() {
    var rawBody = Buffer.concat(chunks);
    var body = rawBody;
    if (req.method === 'POST' && req.url === '/api/chat') {
      try {
        var parsed = JSON.parse(rawBody.toString());
        if (parsed.model && parsed.model.indexOf('-fast') !== -1 && parsed.think === undefined) {
          parsed.think = false;
          body = Buffer.from(JSON.stringify(parsed));
        }
      } catch(e) {}
    }
    var opts = {
      hostname: 'ollama', port: 11434,
      path: req.url, method: req.method,
      headers: Object.assign({}, req.headers, {
        host: 'ollama:11434',
        'content-length': body.length
      })
    };
    var proxy = http.request(opts, function(pr) {
      res.writeHead(pr.statusCode, pr.headers);
      pr.pipe(res);
    });
    proxy.on('error', function(e) {
      if (!res.headersSent) res.writeHead(502);
      res.end('proxy error: ' + e.message);
    });
    proxy.write(body);
    proxy.end();
  });
  req.on('error', function() {});
});
server.listen(11434, '127.0.0.1', function() {
  process.stdout.write('[openclaw] http-proxy: localhost:11434 -> ollama:11434 (think:false for fast models)\n');
});
setInterval(function(){}, 1 << 30);
" &

sleep 1

# ── 9. Start gateway (bind to all interfaces so Docker port-mapping works) ───
echo "[openclaw] Starting gateway — model: $MODEL  bind: lan  port: 18789"
exec openclaw gateway run --bind lan --port 18789
