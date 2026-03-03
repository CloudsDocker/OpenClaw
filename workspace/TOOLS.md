# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for specifics unique to this setup.

## GitHub

Full GitHub API access is configured. **When asked about GitHub PRs or branches: call exec with python3 immediately — never describe steps or ask the user to manually do anything.**

These env vars are available in exec python3:
- GITHUB_TOKEN: set (repo scope, SSO authorized for qantasloyalty)
- GITHUB_REPO: qantasloyalty/lto-terraform-aws
- GITHUB_USERNAME: toddyzh
- GITHUB_BASE_BRANCH: master

### List my open PRs — exec this immediately:

```python
import os, urllib.request, json
h = {"Authorization": "token " + os.environ["GITHUB_TOKEN"], "Accept": "application/vnd.github+json"}
prs = json.load(urllib.request.urlopen(urllib.request.Request(
    "https://api.github.com/repos/" + os.environ["GITHUB_REPO"] + "/pulls?state=open&per_page=50", headers=h)))
mine = [p for p in prs if p["user"]["login"] == os.environ["GITHUB_USERNAME"]]
for p in mine:
    print("#" + str(p["number"]) + ": " + p["title"] + "  " + p["head"]["ref"] + "  " + p["html_url"])
```

### Find my latest branch (skip master/main/develop/staging) — exec this immediately:

```python
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
```

### Create a PR — exec this (fill in BRANCH, TITLE, BODY):

```python
import os, urllib.request, json
h = {"Authorization": "token " + os.environ["GITHUB_TOKEN"],
     "Accept": "application/vnd.github+json", "Content-Type": "application/json"}
data = json.dumps({"head": "BRANCH", "base": os.environ["GITHUB_BASE_BRANCH"],
                   "title": "TITLE", "body": "BODY"}).encode()
pr = json.load(urllib.request.urlopen(urllib.request.Request(
    "https://api.github.com/repos/" + os.environ["GITHUB_REPO"] + "/pulls",
    data=data, headers=h)))
print("PR #" + str(pr["number"]) + ": " + pr["html_url"])
```
