#!/usr/bin/env bash
set -euo pipefail

# start_processing_once.sh
# Launches the Processing sketch once and exits when the wrapper/process ends.

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJ_DIR="$BASE_DIR/projection"
SKETCH_DIR="$PROJ_DIR"
LOG="$BASE_DIR/processing_once.log"

echo "Starting Processing once (sketch=$SKETCH_DIR)" | tee -a "$LOG"

if command -v processing >/dev/null 2>&1; then
  echo "Using 'processing' command" | tee -a "$LOG"
  processing cli --sketch="$SKETCH_DIR" --present >>"$LOG" 2>&1 || true
elif command -v processing-java >/dev/null 2>&1; then
  echo "Using 'processing-java' command" | tee -a "$LOG"
  processing-java --run --sketch="$SKETCH_DIR" --present >>"$LOG" 2>&1 || true
else
  echo "Processing not found; please install or export a runnable jar." | tee -a "$LOG"
  exit 1
fi

echo "Processing run finished" | tee -a "$LOG"
