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

## Weather

**Location:** Killara, Sydney, Australia (lat=-33.775, lon=151.163)
**IMPORTANT: NEVER guess or hallucinate weather data. Always fetch it using exec python3.**

When asked about weather (current, today, tomorrow, this week) — exec this immediately:

```python
import urllib.request, json
from datetime import datetime, timezone, timedelta

lat, lon = -33.775, 151.163
tz = "Australia/Sydney"
url = (
    "https://api.open-meteo.com/v1/forecast"
    f"?latitude={lat}&longitude={lon}"
    "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,wind_speed_10m_max,uv_index_max"
    "&current=temperature_2m,weather_code,wind_speed_10m,relative_humidity_2m"
    f"&timezone={tz}&forecast_days=7"
)
data = json.load(urllib.request.urlopen(url))
wmo = {0:"Clear sky",1:"Mainly clear",2:"Partly cloudy",3:"Overcast",45:"Foggy",48:"Icy fog",
       51:"Light drizzle",53:"Drizzle",55:"Heavy drizzle",61:"Light rain",63:"Rain",65:"Heavy rain",
       71:"Light snow",73:"Snow",75:"Heavy snow",80:"Light showers",81:"Showers",82:"Heavy showers",
       95:"Thunderstorm",96:"Thunderstorm w/ hail",99:"Thunderstorm w/ heavy hail"}
cur = data["current"]
print(f"NOW: {cur['temperature_2m']}°C, {wmo.get(cur['weather_code'],'?')}, wind {cur['wind_speed_10m']} km/h, humidity {cur['relative_humidity_2m']}%")
print()
for i, date in enumerate(data["daily"]["time"]):
    code = data["daily"]["weather_code"][i]
    hi = data["daily"]["temperature_2m_max"][i]
    lo = data["daily"]["temperature_2m_min"][i]
    rain = data["daily"]["precipitation_sum"][i]
    wind = data["daily"]["wind_speed_10m_max"][i]
    uv = data["daily"]["uv_index_max"][i]
    label = ["Today","Tomorrow"][i] if i < 2 else date
    print(f"{label}: {lo}–{hi}°C, {wmo.get(code,'?')}, rain {rain}mm, wind {wind} km/h, UV {uv}")
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
