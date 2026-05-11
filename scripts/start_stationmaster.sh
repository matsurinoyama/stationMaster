#!/usr/bin/env bash
set -euo pipefail

# start_stationmaster.sh
# Starts the downloader loop (background) and then launches the Processing sketch.
# Edit paths below if your user or layout differs.

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJ_DIR="$BASE_DIR/projection"
DOWNLOAD_SCRIPT="$PROJ_DIR/download_faces.py"

echo "Base dir: $BASE_DIR"

# Ensure faces dir exists
mkdir -p "$BASE_DIR/faces"

# Set SSL certs (used by downloader)
export SSL_CERT_FILE="$(python3 -c 'import certifi; print(certifi.where())')"

echo "Starting downloader loop (background)..."
# Run downloader in a resilient loop in background
( while true; do
    python3 "$DOWNLOAD_SCRIPT" || true
    sleep 10
  done ) &
DOWNLOADER_PID=$!
echo $DOWNLOADER_PID > "$BASE_DIR/stationmaster_downloader.pid"

echo "Downloader started (pid=$DOWNLOADER_PID). Sleeping briefly before launching Processing..."
sleep 2

# Forward termination signals to children so systemd stop works cleanly
cleanup() {
  echo "Shutting down children..."
  [ -n "${PROCESS_PID-}" ] && kill "$PROCESS_PID" 2>/dev/null || true
  [ -n "${DOWNLOADER_PID-}" ] && kill "$DOWNLOADER_PID" 2>/dev/null || true
  exit 0
}
trap cleanup SIGTERM SIGINT

# Launch the sketch as a headless exported JAR if available, otherwise try processing-java
JAR_CANDIDATES=("$BASE_DIR/stationmaster.jar" "$PROJ_DIR/stationmaster.jar")
JAR_PATH=""
for c in "${JAR_CANDIDATES[@]}"; do
  if [ -f "$c" ]; then
    JAR_PATH="$c"
    break
  fi
done

# Helper: start a command in background and monitor for the real rendering process.
# Some Processing launchers act as wrappers and exit quickly; this helper will wait
# for wrapper and any children (java/rendering) that reference the sketch directory.
launch_and_monitor() {
  local -a cmd=("$@")
  local LOG="$BASE_DIR/processing.log"
  echo "Launching: ${cmd[*]}" | tee -a "$LOG"
  # Start the wrapper and capture stdout/stderr to the log
  "${cmd[@]}" >>"$LOG" 2>&1 &
  PROCESS_PID=$!
  echo $PROCESS_PID > "$BASE_DIR/stationmaster_processing.pid"
  echo "Processing wrapper PID=$PROCESS_PID" | tee -a "$LOG"

  # Give the wrapper a short moment to spawn any real renderer processes
  sleep 2

  local renderer_found=0

  # Loop until wrapper and any relevant renderer processes are gone.
  while true; do
    if kill -0 "$PROCESS_PID" 2>/dev/null; then
      # Wrapper still running
      sleep 1
      continue
    fi

    # Wrapper exited. Check for child PIDs of the wrapper (may be none if detached)
    CHILD_PIDS="$(pgrep -P "$PROCESS_PID" || true)"
    if [ -n "$CHILD_PIDS" ]; then
      echo "Wrapper exited but children exist: $CHILD_PIDS — waiting on them" | tee -a "$LOG"
      renderer_found=1
      # Wait until no children of the original wrapper remain
      while [ -n "$(pgrep -P "$PROCESS_PID" || true)" ]; do
        sleep 1
      done
      break
    fi

    # If no children, try to find running processes that reference the sketch dir or Processing/Java
    if [ -n "${SKETCH_DIR-}" ] && ( pgrep -f "$SKETCH_DIR" >/dev/null 2>&1 || pgrep -f processing >/dev/null 2>&1 || pgrep -f java >/dev/null 2>&1 ); then
      echo "Found running renderer processes by pattern; assuming renderer is active." | tee -a "$LOG"
      renderer_found=1
      break
    fi

    # No wrapper and no renderer found — dump last lines from log for debugging
    echo "Wrapper exited with no renderer found. Recent output:" | tee -a "$LOG"
    tail -n 50 "$LOG" | sed 's/^/  /' | tee -a "$LOG"
    break
  done

  if [ "$renderer_found" -eq 1 ]; then
    return 0
  else
    return 1
  fi
}

if [ -n "$JAR_PATH" ]; then
  echo "Launching headless JAR: $JAR_PATH"
  # Run with no DISPLAY; the jar should be exported to run without a GUI
  if ! launch_and_monitor java -jar "$JAR_PATH"; then
    echo "Initial JAR launch did not find a renderer."
    if command -v xvfb-run >/dev/null 2>&1; then
      echo "Retrying under xvfb-run..."
      launch_and_monitor xvfb-run -a java -jar "$JAR_PATH"
    fi
  fi
else
  SKETCH_DIR="$PROJ_DIR"
  if command -v processing-java >/dev/null 2>&1; then
    echo "Launching Processing via processing-java --sketch=$SKETCH_DIR --present"
    if ! launch_and_monitor processing-java --run --sketch="$SKETCH_DIR" --present; then
      echo "processing-java wrapper exited without renderer."
      if command -v xvfb-run >/dev/null 2>&1; then
        echo "Retrying under xvfb-run..."
        launch_and_monitor xvfb-run -a processing-java --run --sketch="$SKETCH_DIR" --present
      fi
    fi
  elif command -v processing >/dev/null 2>&1; then
    echo "Launching Processing via processing cli --sketch=$SKETCH_DIR --present"
    if ! launch_and_monitor processing cli --sketch="$SKETCH_DIR" --present; then
      echo "processing wrapper exited without renderer."
      if command -v xvfb-run >/dev/null 2>&1; then
        echo "Retrying under xvfb-run..."
        launch_and_monitor xvfb-run -a processing cli --sketch="$SKETCH_DIR" --present
      fi
    fi
  else
    echo "No runnable JAR or Processing found. Please export a runnable jar named 'stationmaster.jar' into the project root or install processing-java." >&2
    # keep downloader running if Processing not available
    wait $DOWNLOADER_PID
  fi
fi
