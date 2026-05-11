# Deploying StationMaster to Heroku

This guide explains how to deploy the Flask-based face alignment app (`stationMaster`) to Heroku using Docker.

## Prerequisites

- [Heroku CLI](https://devcenter.heroku.com/articles/heroku-cli) installed
- Docker installed (for local testing)
- Git repository initialized in this directory

## Quick Deploy (Recommended: Docker via Heroku Container Registry)

**Why Docker?** MediaPipe requires native libraries that are difficult to install via Heroku's Python buildpack. Using Docker ensures all dependencies are packaged correctly.

### Step 1: Create a Heroku app

```bash
# Navigate to the stationMaster directory
cd works/stationMaster

# Create a new Heroku app (choose a unique name)
heroku create your-app-name

# Optional: specify a region
# heroku create your-app-name --region eu
```

### Step 2: Build and test locally (optional but recommended)

```bash
# Build the Docker image
docker build -t stationmaster:latest .

# Run locally on port 8000
docker run -p 8000:8000 stationmaster:latest

# Test in browser: http://localhost:8000
# Upload a face image and verify alignment works
```

### Step 3: Deploy to Heroku

```bash
# Log in to Heroku Container Registry
heroku container:login

# Build and push the image to Heroku (this may take a few minutes)
heroku container:push web --app your-app-name

# Release the image (makes it live)
heroku container:release web --app your-app-name

# Open the app in your browser
heroku open --app your-app-name
```

### Step 4: Verify deployment

```bash
# Check app logs
heroku logs --tail --app your-app-name

# Check app status
heroku ps --app your-app-name
```

You should see the web dyno running and the Flask server responding to requests.

## Updating the deployed app

After making code changes:

```bash
# Rebuild and push the updated image
heroku container:push web --app your-app-name

# Release the new version
heroku container:release web --app your-app-name
```

## Alternative: Python Buildpack (Not Recommended)

If you prefer to use Heroku's Python buildpack instead of Docker:

```bash
# From works/stationMaster directory
heroku create your-app-name
git add .
git commit -m "Deploy to Heroku"
git push heroku master
```

**Warning:** This may fail due to MediaPipe's native dependencies. If you encounter errors, use the Docker method above.

## Configuration

The app uses these files for deployment:

- `Dockerfile` — builds the container with Python 3.11 and all dependencies
- `Procfile` — tells Heroku to run `gunicorn server:app`
- `requirements.txt` — Python dependencies including MediaPipe, Flask, OpenCV

### Environment Variables

The app doesn't require environment variables for basic operation. If you want to enable Flask debug mode (not recommended in production):

```bash
heroku config:set FLASK_DEBUG=1 --app your-app-name
```

## File Storage

- Uploaded images are stored in the `/uploads` directory
- Aligned faces are stored in the `/faces` directory
- **Note:** Heroku's filesystem is ephemeral. Files are lost when the dyno restarts. For production use, consider using S3 or another persistent storage solution.

## Troubleshooting

### Build fails with MediaPipe errors
- Ensure you're using the Docker deployment method (not buildpack)
- Check that the Dockerfile includes all apt-get dependencies

### App crashes on startup
```bash
# Check logs for errors
heroku logs --tail --app your-app-name

# Common issues:
# - Missing PORT binding: the Dockerfile CMD uses $PORT from Heroku
# - Memory issues: MediaPipe can be memory-intensive; upgrade dyno if needed
```

### Slow performance
- MediaPipe face mesh processing is CPU-intensive
- Consider upgrading to a Performance dyno for production use
- For high traffic, consider offloading processing to a background worker

### Memory quota exceeded (Heroku R14)
If you see logs like `Error R14 (Memory quota exceeded)`, lower your app's memory footprint:

- Use a single Gunicorn worker (we set this by default now):
  - Procfile: `--workers 1 --threads 1`
  - Dockerfile CMD: `--workers 1 --threads 1`
- Recycle workers to avoid leaks: `--max-requests 200 --max-requests-jitter 50`
- Ensure headless dependencies (we already use `opencv-python-headless`).
- Resize or limit upload image size to reduce processing memory (consider setting a Flask `MAX_CONTENT_LENGTH`).
- If needed, upgrade dyno size (Standard-2x or Performance) for more RAM.

After changes, redeploy:

```bash
heroku container:push web --app your-app-name
heroku container:release web --app your-app-name
```

### Cannot access uploaded/aligned images
- The download endpoints are:
  - `GET /faces` — JSON list of all aligned faces with URLs
  - `GET /faces/download_all` — ZIP archive of all aligned faces
  - `GET /faces/<filename>` — individual aligned face image

## Additional Resources

- [Heroku Container Registry docs](https://devcenter.heroku.com/articles/container-registry-and-runtime)
- [MediaPipe Face Mesh](https://google.github.io/mediapipe/solutions/face_mesh.html)
- Client-side download script: `projection/download_faces.py`

## Scaling dynos (throughput vs memory)

There are two ways to increase capacity on Heroku:

1) Scale OUT (more dynos) — increases parallel request capacity

```bash
# Run 2 web dynos (2 containers of your image)
heroku ps:scale web=2 --app your-app-name

# Check dyno formation
heroku ps --app your-app-name
```

Notes:
- Each dyno runs the same container (with Gunicorn `--workers 1`). This helps handle more concurrent requests, but does NOT increase memory per dyno.
- With multiple dynos, the dyno filesystem is not shared. Do not rely on local `/uploads` or `/faces` as shared storage — use S3 or another persistent store.

2) Scale UP (bigger dyno) — increases memory/CPU per dyno

```bash
# Upgrade the web dyno size (examples)
heroku ps:type web=standard-2x --app your-app-name     # ~1GB RAM
# or
heroku ps:type web=performance-m --app your-app-name    # more RAM/CPU, autoscaling eligible
```

Autoscaling (Performance dynos only):

```bash
# Enable autoscaling between 1 and 5 dynos
heroku ps:autoscale:enable web --min=1 --max=5 --app your-app-name
```

Which to choose?
- If you hit R14 (memory quota exceeded) for single requests, scaling OUT won’t fix it — you need to scale UP (bigger dyno) or reduce memory usage.
- If memory is now stable but you need more throughput, scale OUT with more web dynos.



# Language-Specific Directory Structure

## Overview
The application now supports Japanese and English versions in separate directories with automatic language detection.

## Directory Structure

```
works/stationMaster/
├── index_redirect.html     # Root page with auto language detection
├── app.js                  # Shared JavaScript (language-aware)
├── styles.css              # Shared styles
├── server.py              # Flask backend (language-aware)
├── jp/                    # Japanese version
│   ├── index.html         # Japanese upload page
│   └── privacy.html       # Japanese privacy policy
└── en/                    # English version
    ├── index.html         # English upload page
    └── privacy_en.html    # English privacy policy
```

## URL Structure

- **Root**: `eiden.03080.jp/` → Auto-detects language and redirects
- **Japanese**: `eiden.03080.jp/jp/` → Japanese interface
- **English**: `eiden.03080.jp/en/` → English interface

## Language Detection

### Root Page (index_redirect.html)
1. Detects browser language using `navigator.language`
2. If Japanese (`ja`), redirects to `/jp/`
3. Otherwise, redirects to `/en/`
4. Shows manual language selector with 1.5s delay before auto-redirect

### Backend (server.py)
Language detection priority:
1. Checks URL path (`/jp/` or `/en/`)
2. Checks referer header for `index_en.html` or language paths
3. Falls back to `Accept-Language` header
4. Default: Japanese

### Frontend (app.js)
- Reads `data-lang` attribute from `<body>` tag
- Loads appropriate message strings (ja or en)
- All alerts and UI text use language-specific messages

## Server Routes

```python
@app.get("/")              # Serves index_redirect.html (auto-detect)
@app.get("/jp/")           # Serves jp/index.html
@app.get("/en/")           # Serves en/index.html
@app.post("/upload")       # Upload endpoint (language-aware responses)
```

## Features

✅ Automatic language detection based on browser settings
✅ Manual language selection available
✅ All error messages in appropriate language
✅ Clean URL structure (`/jp/` and `/en/`)
✅ Language switcher on each page
✅ Server responses match page language
