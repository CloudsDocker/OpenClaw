#!/bin/bash
# Clipboard relay: watches Telegram session for /paste messages
# On mobile: send "/paste <your text>" to the bot
# Content appears here instantly, no AI processing involved
#
# Usage: bash ~/ws/todd/ai/OpenClaw/shared/watch-clipboard.sh

SHARED_DIR="$(dirname "$(realpath "$0")")"
CLIPBOARD="$SHARED_DIR/clipboard.txt"
SEEN_FILE="$SHARED_DIR/.last_seen_id"
PARSER="$SHARED_DIR/parse-paste.py"

touch "$CLIPBOARD" "$SEEN_FILE"
LAST_SEEN=$(cat "$SEEN_FILE" 2>/dev/null || echo "")

echo "Watching for /paste messages from Telegram..."
echo "On mobile: send '/paste <your text>' to the bot"
echo "Press Ctrl+C to stop"
echo "─────────────────────────────────────────"

while true; do
  # Find the latest session file in the container
  SESSION=$(docker exec openclaw-gateway sh -c \
    "ls -t /root/.openclaw/agents/main/sessions/*.jsonl 2>/dev/null | head -1" 2>/dev/null)

  if [ -z "$SESSION" ]; then
    sleep 2
    continue
  fi

  # Copy the parser into the container and run it
  docker cp "$PARSER" openclaw-gateway:/tmp/parse-paste.py 2>/dev/null

  RESULT=$(docker exec openclaw-gateway python3 /tmp/parse-paste.py "$SESSION" "$LAST_SEEN" 2>/dev/null)

  if [ -n "$RESULT" ]; then
    NEW_LAST=""
    CONTENT=""
    while IFS= read -r line; do
      if [[ "$line" == ID:* ]]; then
        if [ -n "$CONTENT" ]; then
          echo "$CONTENT"
          printf '%s\n---\n' "$CONTENT" >> "$CLIPBOARD"
          CONTENT=""
        fi
        NEW_LAST="${line#ID:}"
      else
        CONTENT="$line"
      fi
    done <<< "$RESULT"

    # Flush last item
    if [ -n "$CONTENT" ]; then
      echo "$CONTENT"
      printf '%s\n---\n' "$CONTENT" >> "$CLIPBOARD"
    fi

    if [ -n "$NEW_LAST" ]; then
      echo "$NEW_LAST" > "$SEEN_FILE"
      LAST_SEEN="$NEW_LAST"
    fi
  fi

  sleep 2
done
