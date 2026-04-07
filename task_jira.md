# Troubleshooting: Integrating REST API Tools into OpenClaw

A practical guide based on real debugging when adding Jira API support to OpenClaw. The patterns here apply to any REST API integration.

---

## The Goal

Add a new tool so the AI agent can call a REST API (Jira in this case) via the `exec python3` mechanism — the same pattern used for GitHub, Azure DevOps, and Weather.

---

## How OpenClaw Tool Integration Works

OpenClaw agents execute API calls by running Python code through the `exec` tool. The integration has three parts:

1. **`.env`** — credentials (never hardcoded)
2. **`docker-compose.yml`** — passes env vars into the container
3. **`openclaw/entrypoint.sh`** — writes `TOOLS.md` (code templates the agent reads) and the system prompt directive (tells the agent *when* to use the tool)

The agent reads `TOOLS.md` at runtime, copies the relevant code template, and runs it via `exec python3`.

---

## What Went Wrong (and Why)

### Problem 1 — Python code running as shell script

**Symptom:**
```
sh: 1: import: not found
sh: 3: domain: not found
sh: 6: Syntax error: "(" unexpected
```

**Cause:** The agent passed the raw Python code to the exec tool without specifying `python3`. The exec tool defaulted to `sh`, which cannot interpret Python.

**Why it happened:** The `TOOLS.md` code template didn't clearly instruct the agent *how* to invoke the exec tool. Without a `python3` prefix in the example, the model improvised incorrectly.

**Fix:** Make TOOLS.md templates unambiguous — label each block `exec this immediately` and ensure the system prompt directive explicitly says `USE EXEC PYTHON3`.

---

### Problem 2 — Quote mangling in `python3 -c "..."`

**Symptom:**
```
File "<string>", line 6
auth = base64.b64encode((email + : + token).encode()).decode()
SyntaxError: invalid syntax
```

The `":"` became `:` — the quotes were stripped.

**Cause:** When the agent converts multi-line Python into a single `python3 -c "..."` call, any double-quoted string literals inside the code (`":"`, `"application/json"`, `"Authorization"`, etc.) conflict with the outer double quotes of the `-c` argument. The shell strips the inner quotes.

**Example of what breaks:**
```bash
# Agent generates this:
python3 -c "auth = base64.b64encode((email + ":" + token).encode()).decode()"
#                                                 ^^^
#                                    Shell sees this as end of string
```

**Fix:** Write all Python string literals in TOOLS.md code templates using **single quotes only**. Single quotes inside `python3 -c "..."` are safe because the outer delimiter is a double quote.

```python
# BAD — breaks inside python3 -c "..."
auth = base64.b64encode((email + ":" + token).encode()).decode()
headers = {"Authorization": "Basic " + auth, "Content-Type": "application/json"}

# GOOD — single quotes survive python3 -c "..." intact
auth = base64.b64encode((email + ':' + token).encode()).decode()
hdrs = {'Authorization': 'Basic ' + auth, 'Content-Type': 'application/json'}
```

---

## The Rules for Writing exec-safe Python in TOOLS.md

| Rule | Bad | Good |
|------|-----|------|
| String literals | `"application/json"` | `'application/json'` |
| Dict keys | `{"key": value}` | `{'key': value}` |
| String concat with special chars | `email + ":" + token` | `email + ':' + token` |
| f-strings with subscripts | `f"{result['key']}"` | `result['key']` (separate line) |
| Multi-line vs single-line | Multi-line preferred in file | Compress to single line for `-c` safety |

### Golden rule
> **Use single quotes for ALL string literals in exec Python templates.** The agent wraps your code in `python3 -c "..."` — double quotes inside will be eaten by the shell.

---

## Adding a New REST API Tool — Checklist

### 1. Add credentials to `.env`
```bash
MY_API_TOKEN=
MY_API_EMAIL=
MY_API_DOMAIN=example.atlassian.net
```

### 2. Pass them through `docker-compose.yml`
```yaml
environment:
  - MY_API_TOKEN=${MY_API_TOKEN:-}
  - MY_API_EMAIL=${MY_API_EMAIL:-}
  - MY_API_DOMAIN=${MY_API_DOMAIN:-}
```

### 3. Write the TOOLS.md section in `entrypoint.sh`

Add a conditional block after the existing tool sections:

```bash
if [ -n "$MY_API_TOKEN" ]; then
  cat >> "${HOME}/.openclaw/workspace/TOOLS.md" << 'MY_TOOL_APPEND'

## My Tool

**Always use exec python3 immediately — never describe steps.**

Env vars available: MY_API_TOKEN (set), MY_API_EMAIL, MY_API_DOMAIN

### Do the thing — exec this immediately:
```python
import os, json, urllib.request, base64
domain = os.environ['MY_API_DOMAIN']
auth   = base64.b64encode((os.environ['MY_API_EMAIL'] + ':' + os.environ['MY_API_TOKEN']).encode()).decode()
hdrs   = {'Authorization': 'Basic ' + auth, 'Accept': 'application/json'}
# ... rest of code using only single-quoted strings
```
MY_TOOL_APPEND
fi
```

Note: Use a **quoted heredoc** (`<< 'MY_TOOL_APPEND'`) if the Python code has no shell variables to expand. Use an unquoted heredoc (`<< MY_TOOL_APPEND`) only when you need `${SHELL_VAR}` expansion inside the content.

### 4. Add a brief mention to the system prompt directive

Inside the directive Python string in section 6c of `entrypoint.sh`, add:

```python
"## My Tool\n"
"MY_API_TOKEN, MY_API_EMAIL, MY_API_DOMAIN env vars are set.\n"
"Full code templates in TOOLS.md under ## My Tool.\n"
"NEVER print the token value.\n"
"\n"
```

### 5. Rebuild and clear sessions
```bash
docker compose build --no-cache openclaw && docker compose up -d openclaw
docker exec openclaw-gateway sh -c "rm -f /root/.openclaw/agents/main/sessions/*.jsonl"
```

Clearing sessions is critical — old conversation history overrides new system prompts.

---

## Debugging Loop

When an exec tool call fails, check in this order:

1. **`sh: import: not found`** → Python code ran as shell. The agent didn't use `python3`. Check that TOOLS.md says "exec python3 immediately" and the system prompt directive covers this tool.

2. **`SyntaxError: invalid syntax` with missing quotes** → Quote mangling in `python3 -c "..."`. Switch all string literals to single quotes.

3. **`NameError` or `KeyError`** → The code ran but logic failed. Check the API response shape — print the raw JSON first to inspect it.

4. **`HTTPError 401`** → Auth failed. Verify `JIRA_EMAIL` + `JIRA_API_TOKEN` are set in `.env` and the container was rebuilt after editing.

5. **`HTTPError 400`** → Payload schema wrong. Jira API v3 requires description in ADF (Atlassian Document Format), not a plain string.

6. **Tool works in isolation but agent ignores it** → Stale session. Clear sessions and retry.

---

## Jira-Specific Notes

- **API version:** Use `/rest/api/3/` (not v2). Description field must be ADF format.
- **Subtask issuetype:** `{'name': 'Sub-task'}` — exact capitalisation matters.
- **Auth:** Basic auth with `email:api_token` base64 encoded — NOT username:password.
- **Project key:** Don't hardcode it. Fetch from the parent issue's `fields.project.key`.
- **API token:** Generate at https://id.atlassian.com/manage-api-tokens (not your Atlassian password).
