#!/bin/sh
# Installs OpenClaw helper scripts into ~/.local/bin

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"

mkdir -p "$BIN_DIR"

install_script() {
  src="$SCRIPT_DIR/$1"
  dst="$BIN_DIR/$1"
  cp "$src" "$dst"
  sed -i 's/\r$//' "$dst"
  chmod +x "$dst"
  echo "Installed: $dst"
}

install_script openclaw-approve

echo "Done. Make sure $BIN_DIR is in your PATH."
