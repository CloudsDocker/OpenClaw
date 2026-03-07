# OpenClaw Exec Tool — Troubleshooting Guide

## Root Cause Analysis: AI Not Using Exec Tool in Telegram

### Problem

When asked via Telegram to list repos, check git status, or fetch weather, the AI responded with generic "run these commands in your terminal" text instead of actually executing the commands.

---

## Root Causes Found (in order of discovery)

### 1. `git` in `safeBins` but no `safeBinProfile` → silently ignored

**Symptom:** Log shows `[exec] ignoring unprofiled safeBins entries (git)`

**Why:** OpenClaw requires *every* binary in `safeBins` to have a matching entry in `safeBinProfiles`. A bin listed without a profile is silently dropped — no error, no warning in normal output.

**Fix:** Add profile for every bin:
```bash
docker exec openclaw-gateway openclaw config set tools.exec.safeBinProfiles.git \
  '{"allowedValueFlags":["-C","log","status","diff","push","pull","--oneline","--stat","-n","--no-pager"]}' \
  2>/dev/null || true
```

---

### 2. Old session history poisoning model behaviour (37,970 tokens)

**Symptom:** Model consistently responds with the old pattern regardless of system prompt changes.

**Why:** The Telegram conversation session accumulated 139 messages of "run these commands yourself" responses. The model pattern-matches to its own prior turns, overriding the system prompt.

**Fix:** Clear the session so the model starts fresh:
```bash
docker exec openclaw-gateway sh -c "
  rm -f /root/.openclaw/agents/main/sessions/*.jsonl
  echo '{}' > /root/.openclaw/agents/main/sessions/sessions.json
"
```

---

### 3. Model sends raw Python code as exec `command` field → allowlist miss

**Symptom:** Log shows `[tools] exec failed: exec denied: allowlist miss`

**Why:** The exec tool schema is `{"command": "shell command string"}`. The model (qwen3:14b) generates raw multiline Python code as the command value:
```
{"command": "import subprocess, os\nbase = os.path.expanduser(...)"}
```
The exec shell parser sees `import` as the binary name → not in `safeBins` → allowlist miss.

The correct format the model *should* generate is:
```
{"command": "python3 -c \"import os; print(...)\""}
```
But the model consistently ignores this even with explicit system prompt examples.

**Fix:** Set exec security to `full` (no allowlist restriction) — appropriate for a single-user personal AI assistant:
```bash
# In entrypoint.sh (line ~38):
openclaw config set tools.exec.security full 2>/dev/null || true

# Then rebuild the image (restart alone won't pick up entrypoint.sh changes):
docker compose build --no-cache openclaw && docker compose up -d openclaw
```

---

### 4. `entrypoint.sh` changes require image rebuild, not just restart

**Symptom:** `docker compose restart` reverts config to the baked-in entrypoint.sh values.

**Why:** The container image bakes `entrypoint.sh` at build time. `docker compose restart` reruns the old image's entrypoint, overwriting any live config changes made with `openclaw config set`.

**Rule:** After editing `openclaw/entrypoint.sh`:
```bash
# WRONG — uses old baked image, overwrites your live config changes:
docker compose restart openclaw

# CORRECT — rebuilds image first:
docker compose build --no-cache openclaw && docker compose up -d openclaw
```

---

### 5. `docker compose restart` does not pick up `docker-compose.yml` env var changes

**Symptom:** Changed `OPENCLAW_MODEL` in `docker-compose.yml` but container still shows old model.

**Why:** `restart` reuses the existing container configuration. `up -d` recreates the container with the new env vars.

**Rule:** After editing `docker-compose.yml`:
```bash
docker compose up -d openclaw   # recreates container with new env
```

---

## Diagnostic Checklist

When the AI ignores exec or gives wrong responses via Telegram:

```bash
# 1. Check exec security mode (must be 'full' or 'allowlist' with correct profiles)
docker exec openclaw-gateway openclaw config get tools.exec.security

# 2. Check for unprofiled safeBins warnings in logs
docker compose logs openclaw | grep "unprofiled\|allowlist miss\|exec denied"

# 3. Check model in use
docker exec openclaw-gateway openclaw config get agents.defaults.model.primary

# 4. Check session token count (>20k tokens = clear the session)
docker exec openclaw-gateway openclaw sessions --json | python3 -m json.tool | grep inputTokens

# 5. Read the actual session to see what tool_use the model generated
docker exec openclaw-gateway python3 -c "
import json, os, glob
files = glob.glob('/root/.openclaw/agents/main/sessions/*.jsonl')
if not files: print('No sessions'); exit()
f = sorted(files, key=os.path.getmtime)[-1]
print('Session:', f)
for line in open(f):
    obj = json.loads(line.strip())
    msg = obj.get('message', {})
    for c in (msg.get('content') or []):
        if c.get('type') == 'toolCall':
            print('TOOL_CALL:', c['name'], '->', str(c.get('arguments',''))[:200])
        if c.get('type') == 'tool_result':
            ci = c.get('content','')
            print('RESULT:', (ci[0]['text'] if isinstance(ci,list) else str(ci))[:200])
"
```

---

## Fix Sequence (full reset)

```bash
# 1. Edit entrypoint.sh if needed (security, safeBinProfiles, system prompt, etc.)
# 2. Rebuild image
docker compose build --no-cache openclaw

# 3. Recreate container (picks up new image + docker-compose.yml env vars)
docker compose up -d openclaw

# 4. Wait for startup
sleep 15 && docker compose logs openclaw --tail=10

# 5. Clear stale session history
docker exec openclaw-gateway sh -c "
  rm -f /root/.openclaw/agents/main/sessions/*.jsonl
  echo '{}' > /root/.openclaw/agents/main/sessions/sessions.json
"

# 6. Verify key settings
docker exec openclaw-gateway openclaw config get tools.exec.security
docker exec openclaw-gateway openclaw config get agents.defaults.model.primary
docker exec openclaw-gateway env | grep OPENCLAW_MODEL
```

---

## Key Config Reference

| Setting | Location | Value |
|---|---|---|
| Exec security | `entrypoint.sh` line ~38 | `full` (personal use) or `allowlist` + profiles |
| Default model | `docker-compose.yml` | `OPENCLAW_MODEL=ollama/qwen3:14b` |
| Telegram system prompt | `openclaw.json` (live) or `entrypoint.sh` (Telegram config section) | Must say "exec SHELL command, start with `python3 -c`" |
| git safe.directory | `entrypoint.sh` | `git config --global --add safe.directory /root/ws/todd/tfnsw/REPO` |

---

## Summary

The final working configuration is:
- **Model:** `ollama/qwen3:14b` (full thinking — needed for tool-calling decisions)
- **Exec security:** `full` (bypasses allowlist — model generates raw Python code, not `python3 -c "..."`)
- **Session:** Clear when token count exceeds ~20k or model behaviour is stuck
- **Changes to `entrypoint.sh`:** Always rebuild image (`docker compose build --no-cache openclaw && docker compose up -d openclaw`)
