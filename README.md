# Everyone's Stationmaster

[![stationMaster_thumb](https://img.youtube.com/vi/sisdm85d3yc/maxresdefault.jpg)](https://youtu.be/sisdm85d3yc)

Visitors upload a photo of their face via a web interface. Their face is then face-aligned using MediaPipe and projected onto a physical face sculpture, making every visitor briefly become the stationmaster.

## How It Works

The installation runs as a Flask web app with the following flow:

1. Visitor opens the web interface on a kiosk or their phone
2. They photograph or upload a selfie
3. The server uses MediaPipe Face Mesh to align and crop the face
4. The aligned face is stored and can be displayed on the projection sculpture
5. A companion script (`projection/download_faces.py`) pulls the latest faces to drive the projection

The interface is bilingual — it auto-detects the visitor's browser language and serves either the Japanese (`/jp/`) or English (`/en/`) version of the page.

## Directory Structure

```
stationMaster/
├── index_redirect.html     # Root page — auto language detection
├── app.js                  # Shared JavaScript (language-aware)
├── styles.css              # Shared styles
├── server.py               # Flask backend (face upload + alignment)
├── jp/                     # Japanese version
│   ├── index.html
│   └── privacy.html
├── en/                     # English version
│   ├── index.html
│   └── privacy_en.html
└── projection/
    └── download_faces.py   # Client-side script to pull faces for projection
```

### URL Structure

| Path                      | Content                                  |
| ------------------------- | ---------------------------------------- |
| `/`                       | Auto-detects language and redirects      |
| `/jp/`                    | Japanese interface                       |
| `/en/`                    | English interface                        |
| `GET /faces`              | JSON list of all aligned faces with URLs |
| `GET /faces/<filename>`   | Individual aligned face image            |
| `GET /faces/download_all` | ZIP archive of all aligned faces         |

## Deploying to Heroku

The app is containerised with Docker because MediaPipe requires native libraries that are difficult to install via Heroku's Python buildpack.

### Prerequisites

- [Heroku CLI](https://devcenter.heroku.com/articles/heroku-cli) installed
- Docker installed (for local testing)

### Step 1: Create a Heroku app

```bash
heroku create your-app-name
```

### Step 2: Build and test locally (optional)

```bash
docker build -t stationmaster:latest .
docker run -p 8000:8000 stationmaster:latest
# Visit http://localhost:8000
```

### Step 3: Deploy

```bash
heroku container:login
heroku container:push web --app your-app-name
heroku container:release web --app your-app-name
heroku open --app your-app-name
```

### Step 4: Verify

```bash
heroku logs --tail --app your-app-name
heroku ps --app your-app-name
```

### Updating after code changes

```bash
heroku container:push web --app your-app-name
heroku container:release web --app your-app-name
```

## Configuration

| File               | Purpose                                                    |
| ------------------ | ---------------------------------------------------------- |
| `Dockerfile`       | Builds the container with Python 3.11 and all dependencies |
| `Procfile`         | Tells Heroku to run `gunicorn server:app`                  |
| `requirements.txt` | Python dependencies (MediaPipe, Flask, OpenCV)             |

The app requires no environment variables for basic operation. To enable Flask debug mode (development only):

```bash
heroku config:set FLASK_DEBUG=1 --app your-app-name
```

### File Storage

Uploaded images are stored in `/uploads` and aligned faces in `/faces`. Heroku's filesystem is ephemeral — files are lost on dyno restart. For a persistent installation, use S3 or another object store.

## Scaling

**Scale out** (more parallel capacity):

```bash
heroku ps:scale web=2 --app your-app-name
```

**Scale up** (more memory/CPU per dyno):

```bash
heroku ps:type web=standard-2x --app your-app-name
```

**Autoscaling** (Performance dynos only):

```bash
heroku ps:autoscale:enable web --min=1 --max=5 --app your-app-name
```

Use scale-up if you hit R14 (memory quota exceeded) on single requests. Use scale-out if memory is stable but you need more throughput. Note: with multiple dynos the local filesystem is not shared — `/faces` will differ between dynos.

## Troubleshooting

**Build fails with MediaPipe errors** — use the Docker deployment method, not the buildpack.

**App crashes on startup** — check `heroku logs --tail`. Common causes: missing `$PORT` binding, or MediaPipe memory pressure (upgrade dyno size).

**R14 memory quota exceeded** — the Procfile and Dockerfile already use `--workers 1 --threads 1` and `--max-requests 200`. If it persists, limit upload image size (`MAX_CONTENT_LENGTH` in Flask) or upgrade to a Standard-2x dyno.

**Slow performance** — MediaPipe face mesh is CPU-intensive. Performance dynos will help for high-traffic events.

## Additional Resources

- [Heroku Container Registry docs](https://devcenter.heroku.com/articles/container-registry-and-runtime)
- [MediaPipe Face Mesh](https://google.github.io/mediapipe/solutions/face_mesh.html)
