#!/usr/bin/env python3
import json, sys, os

session_file = sys.argv[1]
last_seen    = sys.argv[2] if len(sys.argv) > 2 else ""

found_last = (last_seen == "")

try:
    for line in open(session_file):
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if obj.get('type') != 'message':
            continue
        entry_id = obj.get('id', '')
        msg = obj.get('message', {})
        if msg.get('role') != 'user':
            continue

        if not found_last:
            if entry_id == last_seen:
                found_last = True
            continue

        for c in (msg.get('content') or []):
            if c.get('type') != 'text':
                continue
            txt = c['text']
            actual = ''
            for l in reversed(txt.split('\n')):
                l = l.strip()
                if l and not l.startswith('{') and not l.startswith('`') and not l.startswith('"'):
                    actual = l
                    break
            if actual.lower().startswith('/paste ') or actual.lower().startswith('/clip '):
                content = actual.split(' ', 1)[1] if ' ' in actual else ''
                print(f"ID:{entry_id}")
                print(content)
except Exception as e:
    sys.stderr.write(f"parse error: {e}\n")
