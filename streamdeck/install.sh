#!/bin/bash
# Installs the Claude Tasks Stream Deck plugin (macOS).
# Usage: ./install.sh
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/com.jamesschuler.claude-tasks.sdPlugin" && pwd)"
DEST="$HOME/Library/Application Support/com.elgato.StreamDeck/Plugins/com.jamesschuler.claude-tasks.sdPlugin"

if [ ! -d "$HOME/Library/Application Support/com.elgato.StreamDeck" ]; then
  echo "Stream Deck app not found. Install it from https://www.elgato.com/downloads first."
  exit 1
fi

echo "Installing plugin dependencies..."
(cd "$PLUGIN_DIR" && npm install --no-fund --no-audit)

echo "Linking plugin into Stream Deck..."
rm -rf "$DEST"
ln -s "$PLUGIN_DIR" "$DEST"

echo "Restarting Stream Deck..."
osascript -e 'quit app "Elgato Stream Deck"' 2>/dev/null || true
sleep 2
open -a "Elgato Stream Deck" 2>/dev/null || open -a "Stream Deck" 2>/dev/null || true

echo "Done. Drag 'Claude Tasks > Session Status' onto a key."
