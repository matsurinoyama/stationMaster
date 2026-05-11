FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
# Reduce glibc arena count to limit memory fragmentation in multi-threaded apps
ENV MALLOC_ARENA_MAX=2

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libglib2.0-0 \
    libsm6 \
    libxrender1 \
    libxext6 \
    libgl1 \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --upgrade pip
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Expose a default port for documentation; Heroku will provide $PORT at runtime.
EXPOSE 8000

# Use a shell command so the $PORT environment variable (provided by Heroku) is expanded.
# If PORT is not set, fall back to 8000 for local testing.
CMD ["sh", "-c", "gunicorn server:app --bind 0.0.0.0:${PORT:-8000} --workers 2 --threads 4 --max-requests 200 --max-requests-jitter 50 --timeout 120"]
