#!/usr/bin/env bash
# Serve the editor on http://localhost:8765 — a secure context, which Web Bluetooth requires.
cd "$(dirname "$0")"
PORT="${1:-8765}"
echo "PeriPage editor → http://localhost:$PORT/"
exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory public
