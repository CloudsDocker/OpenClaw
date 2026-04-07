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
# Trust the fixed Docker bridge subnet (172.30.0.0/24) so Caddy reverse proxy headers are accepted
openclaw config set gateway.trustedProxies '["172.30.0.0/24"]' 2>/dev/null || true

# ── 3b. Exec tool — allow safe binaries the agent may call ───────────────────
openclaw config set tools.exec.security full 2>/dev/null || true
openclaw config set tools.exec.safeBins '["curl","python3","git"]' 2>/dev/null || true
openclaw config set tools.exec.safeBinProfiles.git '{"allowedValueFlags":["-C","--work-tree","--git-dir","--no-pager","log","status","diff","push","pull","fetch","branch","checkout","rev-parse","--abbrev-ref","HEAD","--oneline","--stat","-n","--decorate","--all","-10","-20"]}' 2>/dev/null || true
# Shared clipboard — ensure file exists and is world-writable so the WSL host user can read/touch it
touch /root/shared/clipboard.txt 2>/dev/null || true
chmod 666 /root/shared/clipboard.txt 2>/dev/null || true

# Allow git to operate on ALL bind-mounted host repos (different uid ownership)
# Dynamically discover every repo under tfnsw and mark it safe
for repo_dir in /root/ws/todd/tfnsw/*/; do
  [ -d "$repo_dir/.git" ] && git config --global --add safe.directory "$repo_dir" 2>/dev/null || true
done
git config --global --add safe.directory /root/ws/todd/tfnsw 2>/dev/null || true

# Configure ADO credentials so git pull/push works non-interactively
# Uses the ADO_PAT env var; safe because this container is single-user personal use
if [ -n "$ADO_PAT" ]; then
  git config --global credential.helper store
  printf 'https://EAPlatformServices:%s@dev.azure.com\n' "$ADO_PAT" \
    > /root/.git-credentials
  chmod 600 /root/.git-credentials
  git config --global url."https://EAPlatformServices:${ADO_PAT}@dev.azure.com".insteadOf \
    "https://dev.azure.com" 2>/dev/null || true
fi
# Empty profiles = no flag restrictions; required or the binaries are silently ignored
openclaw config set tools.exec.safeBinProfiles.curl '{"allowedValueFlags":["-H","-X","-d","-o","-s","-f","-L","-u","-A","-b","-c","-e","--header","--request","--data","--output","--silent","--fail","--location","--user","--user-agent","--cookie","--cookie-jar","--referer","--max-time","--connect-timeout","-m","--url"]}' 2>/dev/null || true
openclaw config set tools.exec.safeBinProfiles.python3 '{"allowedValueFlags":["-c","-m","-u","-W","-E"]}' 2>/dev/null || true
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

# ── Seed workspace files from image on first start (skip if already present) ──
if [ -d "/workspace-seed" ]; then
  for f in /workspace-seed/*.md; do
    name=$(basename "$f")
    if [ ! -f "$WORKSPACE_DIR/$name" ]; then
      cp "$f" "$WORKSPACE_DIR/$name"
      echo "[openclaw] Seeded workspace/$name"
    fi
  done
  if [ -d "/workspace-seed/memory" ]; then
    mkdir -p "$WORKSPACE_DIR/../memory"
    for f in /workspace-seed/memory/*.md; do
      [ -f "$f" ] || continue
      name=$(basename "$f")
      dest="$WORKSPACE_DIR/../memory/$name"
      if [ ! -f "$dest" ]; then
        cp "$f" "$dest"
        echo "[openclaw] Seeded memory/$name"
      fi
    done
  fi
fi

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

# ── Append Weather + TfNSW sections (quoted heredoc — safe for backticks) ────
cat >> "${HOME}/.openclaw/workspace/TOOLS.md" << 'TOOLS_APPEND'

## Weather

**Location:** Killara, Sydney, Australia (lat=-33.775, lon=151.163)
**IMPORTANT: NEVER guess or hallucinate weather data. Always fetch it using exec python3.**

When asked about weather (current, today, tomorrow, this week) — exec this immediately:

```python
import urllib.request, json
lat, lon = -33.775, 151.163
url = (
    "https://api.open-meteo.com/v1/forecast"
    f"?latitude={lat}&longitude={lon}"
    "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,wind_speed_10m_max,uv_index_max"
    "&current=temperature_2m,weather_code,wind_speed_10m,relative_humidity_2m"
    "&timezone=Australia%2FSydney&forecast_days=7"
)
data = json.load(urllib.request.urlopen(url))
wmo = {0:"Clear sky",1:"Mainly clear",2:"Partly cloudy",3:"Overcast",45:"Foggy",48:"Icy fog",
       51:"Light drizzle",53:"Drizzle",55:"Heavy drizzle",61:"Light rain",63:"Rain",65:"Heavy rain",
       71:"Light snow",73:"Snow",75:"Heavy snow",80:"Light showers",81:"Showers",82:"Heavy showers",
       95:"Thunderstorm",96:"Thunderstorm w/ hail",99:"Thunderstorm w/ heavy hail"}
cur = data["current"]
print(f"NOW: {cur['temperature_2m']}C, {wmo.get(cur['weather_code'],'?')}, wind {cur['wind_speed_10m']} km/h, humidity {cur['relative_humidity_2m']}%")
print()
for i, date in enumerate(data["daily"]["time"]):
    code = data["daily"]["weather_code"][i]
    hi = data["daily"]["temperature_2m_max"][i]
    lo = data["daily"]["temperature_2m_min"][i]
    rain = data["daily"]["precipitation_sum"][i]
    wind = data["daily"]["wind_speed_10m_max"][i]
    uv = data["daily"]["uv_index_max"][i]
    label = ["Today","Tomorrow"][i] if i < 2 else date
    print(f"{label}: {lo}-{hi}C, {wmo.get(code,'?')}, rain {rain}mm, wind {wind} km/h, UV {uv}")
```

## TfNSW — Azure DevOps Git Operations

**Repos are cloned under:** ~/ws/todd/tfnsw/
**Available repos:** azure-devops-pipeline-template (ADO pipeline templates)
**ADO:** Org=EAPlatformServices  Project=PlatformServices

**CRITICAL: When asked for ANY git operation (log, status, push, PR, branch list) — exec python3 with subprocess immediately. NEVER describe steps or say you cannot access the filesystem.**

### List repos — exec this immediately:
```python
import subprocess, os
base = os.path.expanduser("~/ws/todd/tfnsw")
result = subprocess.run(["ls", "-la", base], capture_output=True, text=True)
print(result.stdout or result.stderr)
```

### Git log — exec this immediately:
```python
import subprocess, os
repo = os.path.expanduser("~/ws/todd/tfnsw/azure-devops-pipeline-template")
result = subprocess.run(["git", "-C", repo, "log", "--oneline", "-10"], capture_output=True, text=True)
print(result.stdout or result.stderr)
```

### Git status / pending changes — exec this immediately:
```python
import subprocess, os
repo = os.path.expanduser("~/ws/todd/tfnsw/azure-devops-pipeline-template")
for cmd in [["git", "-C", repo, "status"], ["git", "-C", repo, "diff", "--stat"]]:
    r = subprocess.run(cmd, capture_output=True, text=True)
    print(r.stdout or r.stderr)
```

### Git push — exec this immediately:
```python
import subprocess, os
repo = os.path.expanduser("~/ws/todd/tfnsw/azure-devops-pipeline-template")
result = subprocess.run(["git", "-C", repo, "push"], capture_output=True, text=True)
print(result.stdout + result.stderr)
```

### Create ADO Pull Request — exec this immediately:
```python
import subprocess, json, urllib.request, urllib.error, os, base64
PAT = os.environ.get("ADO_PAT", "")
org, proj, repo_name = "EAPlatformServices", "PlatformServices", "azure-devops-pipeline-template"
repo_path = os.path.expanduser("~/ws/todd/tfnsw/" + repo_name)
branch = subprocess.run(["git", "-C", repo_path, "rev-parse", "--abbrev-ref", "HEAD"],
    capture_output=True, text=True).stdout.strip()
url = f"https://dev.azure.com/{org}/{proj}/_apis/git/repositories/{repo_name}/pullrequests?api-version=7.1"
payload = json.dumps({
    "sourceRefName": f"refs/heads/{branch}",
    "targetRefName": "refs/heads/PRD",
    "title": "TITLE",
    "description": "DESCRIPTION"
}).encode()
token = base64.b64encode(f":{PAT}".encode()).decode()
req = urllib.request.Request(url, data=payload,
    headers={"Authorization": f"Basic {token}", "Content-Type": "application/json"})
pr = json.load(urllib.request.urlopen(req))
print(f"PR #{pr['pullRequestId']}: {pr['title']}")
print(pr['url'].replace('_apis/git/repositories', '_git').replace('/pullrequests/', '/pullrequest/'))
```

### List open PRs — exec this immediately:
```python
import urllib.request, json, os, base64
PAT = os.environ.get("ADO_PAT", "")
org, proj, repo_name = "EAPlatformServices", "PlatformServices", "azure-devops-pipeline-template"
url = f"https://dev.azure.com/{org}/{proj}/_apis/git/repositories/{repo_name}/pullrequests?searchCriteria.status=active&api-version=7.1"
token = base64.b64encode(f":{PAT}".encode()).decode()
req = urllib.request.Request(url, headers={"Authorization": f"Basic {token}"})
prs = json.load(urllib.request.urlopen(req))
for pr in prs["value"]:
    print(f"PR #{pr['pullRequestId']}: {pr['title']}  [{pr['sourceRefName'].split('/')[-1]} -> {pr['targetRefName'].split('/')[-1]}]")
```
TOOLS_APPEND
echo "[openclaw] Weather + TfNSW sections appended to TOOLS.md"
fi

# ── 4b. Append Jira section to TOOLS.md ──────────────────────────────────────
if [ -n "$JIRA_API_TOKEN" ]; then
  JIRA_DOMAIN_VAL="${JIRA_DOMAIN:-qantas.atlassian.net}"
  JIRA_EMAIL_VAL="${JIRA_EMAIL:-}"
  cat >> "${HOME}/.openclaw/workspace/TOOLS.md" << JIRA_APPEND

## Jira

**NEVER guess or hallucinate Jira data. Always use exec python3 with the Jira REST API.**

These env vars are available in exec python3:
- JIRA_API_TOKEN: set
- JIRA_EMAIL: ${JIRA_EMAIL_VAL}
- JIRA_DOMAIN: ${JIRA_DOMAIN_VAL}

### Create a subtask under a parent issue — exec this immediately:
\`\`\`python
import os, json, urllib.request, base64
domain = os.environ['JIRA_DOMAIN']
email  = os.environ['JIRA_EMAIL']
token  = os.environ['JIRA_API_TOKEN']
auth   = base64.b64encode((email + ':' + token).encode()).decode()
hdrs = {'Authorization': 'Basic ' + auth, 'Content-Type': 'application/json', 'Accept': 'application/json'}
parent_key    = 'DATAPLATCORE-783'
subtask_title = 'run time error'
subtask_desc  = 'there is task ecs timeout error'
req = urllib.request.Request('https://' + domain + '/rest/api/3/issue/' + parent_key + '?fields=project', headers=hdrs)
proj = json.load(urllib.request.urlopen(req))['fields']['project']['key']
body = json.dumps({'fields': {'project': {'key': proj}, 'parent': {'key': parent_key}, 'summary': subtask_title, 'description': {'type': 'doc', 'version': 1, 'content': [{'type': 'paragraph', 'content': [{'type': 'text', 'text': subtask_desc}]}]}, 'issuetype': {'name': 'Sub-task'}}}).encode()
req2 = urllib.request.Request('https://' + domain + '/rest/api/3/issue', data=body, headers=hdrs)
r = json.load(urllib.request.urlopen(req2))
print('Created: ' + r['key'] + '  https://' + domain + '/browse/' + r['key'])
\`\`\`

### Get issue details — exec this immediately:
\`\`\`python
import os, json, urllib.request, base64
domain = os.environ['JIRA_DOMAIN']
auth   = base64.b64encode((os.environ['JIRA_EMAIL'] + ':' + os.environ['JIRA_API_TOKEN']).encode()).decode()
key    = 'DATAPLATCORE-783'
issue  = json.load(urllib.request.urlopen(urllib.request.Request('https://' + domain + '/rest/api/3/issue/' + key, headers={'Authorization': 'Basic ' + auth, 'Accept': 'application/json'})))
f = issue['fields']
print(issue['key'] + ': ' + f['summary'])
print('Status: ' + f['status']['name'] + '  Type: ' + f['issuetype']['name'])
for s in f.get('subtasks', []):
    print('  ' + s['key'] + ': ' + s['fields']['summary'])
\`\`\`

### Search issues (JQL) — exec this immediately:
\`\`\`python
import os, json, urllib.request, urllib.parse, base64
domain = os.environ['JIRA_DOMAIN']
auth   = base64.b64encode((os.environ['JIRA_EMAIL'] + ':' + os.environ['JIRA_API_TOKEN']).encode()).decode()
jql    = 'assignee = currentUser() AND status != Done ORDER BY updated DESC'
data   = json.load(urllib.request.urlopen(urllib.request.Request('https://' + domain + '/rest/api/3/search?jql=' + urllib.parse.quote(jql) + '&maxResults=20', headers={'Authorization': 'Basic ' + auth, 'Accept': 'application/json'})))
for i in data['issues']:
    print(i['key'] + ': ' + i['fields']['summary'] + ' [' + i['fields']['status']['name'] + ']')
\`\`\`
JIRA_APPEND
  echo "[openclaw] Jira section appended to TOOLS.md"
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
    # <model>-fast — smaller context, thinking disabled via providerOptions
    is_fast = name == "$MODEL_NAME-fast"
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
  python3 - << 'PYEOF'
import json, os

cfg_file = os.path.join(os.path.expanduser('~'), '.openclaw', 'openclaw.json')
try:
    with open(cfg_file) as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}

repo         = os.environ.get('GITHUB_REPO', 'unknown/repo')
user         = os.environ.get('GITHUB_USERNAME', 'unknown')
base         = os.environ.get('GITHUB_BASE_BRANCH', 'master')
jira_domain  = os.environ.get('JIRA_DOMAIN', '')
jira_email   = os.environ.get('JIRA_EMAIL', '')
jira_enabled = bool(os.environ.get('JIRA_API_TOKEN', ''))

jira_section = ""
if jira_enabled:
    jira_section = (
        "## Jira\\n"
        "JIRA_API_TOKEN is set. JIRA_EMAIL=" + jira_email + " JIRA_DOMAIN=" + jira_domain + "\\n"
        "Auth: Basic base64(JIRA_EMAIL:JIRA_API_TOKEN).\\n"
        "CREATE SUBTASK: POST /rest/api/3/issue — fields: project.key, parent.key, summary, description (ADF doc format), issuetype.name=Sub-task.\\n"
        "GET ISSUE: GET /rest/api/3/issue/{key}.\\n"
        "SEARCH: GET /rest/api/3/search?jql=<url-encoded JQL>.\\n"
        "Full ready-to-run code templates are in TOOLS.md under ## Jira.\\n"
        "NEVER print the token value.\\n"
        "\\n"
    )

directive = (
    "You are a personal dev assistant. "
    "\\n\\n"
    "## THE ONE RULE THAT OVERRIDES EVERYTHING ELSE\\n"
    "You have the exec tool. For ANY question about files, folders, git, repos, weather, GitHub, or system state: "
    "USE EXEC PYTHON3 IMMEDIATELY and show the real output. "
    "NEVER say you cannot access the filesystem. "
    "NEVER describe commands for the user to run themselves. "
    "NEVER list options or ask clarifying questions when you can just run the code. "
    "Just execute and show results.\\n"
    "\\n"
    "## File system & Git (TfNSW repos)\\n"
    "Repos live at: ~/ws/todd/tfnsw/\\n"
    "To list repos: exec python3 -> import subprocess,os; r=subprocess.run(['ls','-la',os.path.expanduser('~/ws/todd/tfnsw')],capture_output=True,text=True); print(r.stdout)\\n"
    "To git log:    exec python3 -> subprocess with ['git','-C',<repo_path>,'log','--oneline','-10']\\n"
    "To git status: exec python3 -> subprocess with ['git','-C',<repo_path>,'status']\\n"
    "To git push:   exec python3 -> subprocess with ['git','-C',<repo_path>,'push']\\n"
    "ADO_PAT env var is set for Azure DevOps API calls.\\n"
    "ADO org=EAPlatformServices project=PlatformServices\\n"
    "\\n"
    "## GitHub\\n"
    "GITHUB_TOKEN, GITHUB_REPO=" + repo + ", GITHUB_USERNAME=" + user + ", GITHUB_BASE_BRANCH=" + base + "\\n"
    "GitHub REST API: https://api.github.com — always use Authorization: token <GITHUB_TOKEN>\\n"
    "LIST MY PRs: GET /repos/" + repo + "/pulls?state=open&per_page=50 filtered by user.login==" + user + "\\n"
    "CREATE PR: POST /repos/" + repo + "/pulls with head, base, title, body\\n"
    "NEVER print the token value.\\n"
    "\\n"
) + jira_section + (
    "## Weather\\n"
    "NEVER guess weather. Use exec python3 to call Open-Meteo API. Location and code template are in TOOLS.md.\\n"
    "\\n"
    "## Language\\n"
    "Detect the language of each user message and reply in the SAME language.\\n"
    "If the user writes in Chinese (简体中文), reply entirely in Simplified Chinese.\\n"
    "If the user writes in English, reply in English.\\n"
    "Never mix languages in a single reply unless the user explicitly asks.\\n"
    "\\n"
    "## Clipboard relay\\n"
    "If the message starts with /paste or /clip, extract ALL text after the command word and:\\n"
    "1. exec python3 -c \\\"open('/root/shared/clipboard.txt','a').write(content+'\\\\n---\\\\n')\\\"\\n"
    "   where content is the exact raw text the user sent (verbatim, no changes).\\n"
    "2. Reply only: Saved to clipboard (N chars) — nothing else.\\n"
    "Do NOT analyse, summarise, or comment on the pasted content.\\n"
    "\\n"
    "## Format\\n"
    "Reply concisely. No markdown headers in Telegram. Use plain text and short bullet lines."
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
# Build desired entries with providerOptions for <model>-fast variant
entries = []
for m in tags:
    n = m['name']
    fast = n == '$MODEL_NAME-fast'
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
