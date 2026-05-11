#!/bin/bash
# Temporary test harness for download_faces.py
# Run this manually and Ctrl+C to stop - no automatic startup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"

echo "=========================================="
echo "  Download Test Mode"
echo "=========================================="
echo "This will poll every 10 seconds"
echo "Press Ctrl+C at any time to stop"
echo ""
echo "Monitoring: https://eiden.03080.jp/faces"
echo "Saving to: $SCRIPT_DIR/../faces/"
echo "Database: $SCRIPT_DIR/../faces/.faces_db.sqlite"
echo ""
echo "Starting in 3 seconds..."
sleep 3

iteration=0
while true; do
  iteration=$((iteration + 1))
  echo ""
  echo "========== Iteration $iteration at $(date '+%H:%M:%S') =========="
  
  python3 "$SCRIPT_DIR/download_faces.py" --workers 4
  
  echo ""
  echo "Waiting 10 seconds... (Ctrl+C to stop)"
  sleep 10
done
