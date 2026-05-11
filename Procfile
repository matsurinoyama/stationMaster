web: gunicorn server:app \
	--workers 2 \
	--threads 4 \
	--max-requests 200 \
	--max-requests-jitter 50 \
	--timeout 120
