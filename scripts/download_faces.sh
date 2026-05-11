#!/bin/bash
# Simplified polling script - just runs the downloader periodically
# No change detection needed since the downloader handles it

export SSL_CERT_FILE="$(python3 -c 'import certifi; print(certifi.where())')"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

trap 'echo "Exiting..."; exit 0' INT TERM

echo "Starting face downloader (simplified mode)..."
echo "Polling every 10 seconds. Press Ctrl+C to stop."

while true; do
  python3 "$SCRIPT_DIR/download_faces.py"
  sleep 10
done
