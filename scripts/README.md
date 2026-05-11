StationMaster startup instructions (Raspberry Pi)

This folder contains two helpful files:

- `start_stationmaster.sh` — shell wrapper that runs the downloader loop and then launches the Processing sketch.
- `stationmaster.service` — a systemd unit you can install to start the script at boot.

Quick install (assumes user `pi` and sketch location `~/works/stationMaster`):

1. Make the script executable:

```bash
chmod +x /home/matsurinoyama/stationMaster/scripts/start_stationmaster.sh
```

2. Copy the systemd service to system location and enable it:

```bash
sudo cp /home/matsurinoyama/stationMaster/scripts/stationmaster.service /etc/systemd/system/
# Edit the service file if your username or paths differ (User= and ExecStart=)
sudo systemctl daemon-reload
sudo systemctl enable stationmaster.service
sudo systemctl start stationmaster.service
```

3. Display / X considerations:

- The service sets `DISPLAY=:0` and `XAUTHORITY=/home/pi/.Xauthority` which works if the `pi` user auto-logs into the graphical session. If you use a different display user or different home path, edit `stationmaster.service` accordingly.
- If you prefer to run headless (no X), export the Processing sketch as an executable JAR and modify `start_stationmaster.sh` to run the jar instead of `processing-java`.

4. Logs

- To view logs from the service:

```bash
journalctl -u stationmaster.service -f
```

5. Optional: Run without systemd

You can also run the script directly in a tmux session:

```bash
cd ~/works/stationMaster
./scripts/start_stationmaster.sh
```

If you want, I can modify the service or script to run the sketch headlessly (exported jar), resize images on download, or add a supervisor wrapper. Let me know which option you'd like.

Alternative (recommended): split downloader and Processing into two units

If the combined startup causes issues (Processing wrapper exiting under systemd), use the split services included in this repo. They separate the continuous downloader from the one-shot Processing launcher.

- `scripts/stationmaster-downloader.service` + `scripts/downloader_loop.sh`: runs the downloader continuously and restarts on failure.
- `scripts/stationmaster-processing.service` + `scripts/start_processing_once.sh`: starts the Processing sketch once at boot (does not auto-restart by default).

Install and enable the split units:

```bash
sudo cp /home/matsurinoyama/stationMaster/scripts/stationmaster-downloader.service /etc/systemd/system/
sudo cp /home/matsurinoyama/stationMaster/scripts/stationmaster-processing.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable stationmaster-downloader.service
sudo systemctl enable stationmaster-processing.service
sudo systemctl start stationmaster-downloader.service
sudo systemctl start stationmaster-processing.service
```

Disable the old combined service if you previously installed it:

```bash
sudo systemctl disable --now stationmaster.service || true
```

Notes:
- The processing unit is a oneshot unit that runs Processing once and exits. If you prefer automatic restarts on failure, change `Type=oneshot` in `stationmaster-processing.service` to `Type=simple` and add `Restart=on-failure`.
- If your graphical session doesn't use `:0` or uses Wayland, consider running Processing under `xvfb-run` or running the processing service as a user unit inside your graphical session.
