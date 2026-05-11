#!/usr/bin/env python3
"""
Persistent-storage downloader using SQLite to track downloaded files.
Prevents phantom downloads by maintaining a reliable database of what's been downloaded.
"""
import os
import shutil
import sqlite3
import hashlib
from urllib.request import urlopen, Request
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed

FACES_INDEX_URL = "https://eiden.03080.jp/faces"
BASE_DIR = os.path.dirname(__file__)
OUT_DIR = os.path.normpath(os.path.join(BASE_DIR, '..', 'faces'))
DB_PATH = os.path.join(OUT_DIR, '.faces_db.sqlite')

os.makedirs(OUT_DIR, exist_ok=True)


def init_db():
    """Initialize SQLite database for tracking downloads."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS downloads (
            remote_filename TEXT PRIMARY KEY,
            local_filename TEXT NOT NULL,
            url_hash TEXT NOT NULL,
            downloaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ''')
    conn.commit()
    return conn


def fetch_json(url, timeout=20):
    try:
        import requests
        r = requests.get(url, timeout=timeout)
        r.raise_for_status()
        return r.json()
    except Exception:
        req = Request(url, headers={'User-Agent': 'python-urllib/3'})
        with urlopen(req, timeout=timeout) as r:
            import json
            return json.load(r)


def download_file_requests(session, url, dest_path, timeout=60, retries=2):
    tmp = dest_path + '.tmp'
    last_err = None
    for attempt in range(retries + 1):
        try:
            with session.get(url, stream=True, timeout=timeout) as r:
                r.raise_for_status()
                with open(tmp, 'wb') as f:
                    for chunk in r.iter_content(chunk_size=8192):
                        if chunk:
                            f.write(chunk)
            os.replace(tmp, dest_path)
            return True
        except Exception as e:
            last_err = e
    print('Failed to download (requests):', url, last_err)
    return False


def download_file_urllib(url, dest_path, timeout=60):
    tmp = dest_path + '.tmp'
    req = Request(url, headers={'User-Agent': 'python-urllib/3'})
    with urlopen(req, timeout=timeout) as r, open(tmp, 'wb') as f:
        shutil.copyfileobj(r, f)
    os.replace(tmp, dest_path)


def get_next_available_number(directory):
    """Find the next available aligned_N number in the directory."""
    max_num = 0
    if os.path.exists(directory):
        for fn in os.listdir(directory):
            if fn.lower().startswith('aligned_'):
                try:
                    base = os.path.splitext(fn)[0]
                    num_str = base.split('_')[1]
                    num = int(num_str)
                    max_num = max(max_num, num)
                except (ValueError, IndexError):
                    continue
    return max_num + 1


def main(workers=4):
    print('Querying index:', FACES_INDEX_URL)
    
    # Initialize database
    conn = init_db()
    cursor = conn.cursor()
    
    try:
        items = fetch_json(FACES_INDEX_URL)
    except Exception as e:
        print('Failed to fetch index:', e)
        conn.close()
        return

    if not isinstance(items, list):
        print('Index response is not a list; aborting')
        conn.close()
        return

    # Get already downloaded files from database
    cursor.execute('SELECT remote_filename, local_filename, url_hash FROM downloads')
    db_records = {row[0]: (row[1], row[2]) for row in cursor.fetchall()}
    print(f"Database has {len(db_records)} tracked downloads")

    try:
        import requests
        session = requests.Session()

        tasks = []  # (remote_fn, display_name, url, dest_path, url_hash)
        
        for it in items:
            fn = it.get('filename') if isinstance(it, dict) else None
            url = it.get('url') if isinstance(it, dict) else None
            if not fn or not url:
                continue
            
            # Skip non-image files (DS_Store, hidden files, etc.)
            fn_lower = fn.lower()
            if not fn_lower.startswith('aligned_') or not (fn_lower.endswith('.jpg') or fn_lower.endswith('.jpeg') or fn_lower.endswith('.png')):
                print(f"Skipping non-image file: {fn}")
                continue

            # Hash the URL to detect if same filename points to different content
            url_hash = hashlib.sha256(url.encode()).hexdigest()[:16]
            
            # Check if we've already downloaded this remote filename
            if fn in db_records:
                local_fn, stored_hash = db_records[fn]
                local_path = os.path.join(OUT_DIR, local_fn)
                
                # If file exists locally, assume it's the same unless URL hash changed significantly
                # This handles Heroku dyno restarts where URLs might get minor query param changes
                if os.path.exists(local_path):
                    if stored_hash == url_hash:
                        print(f"Already downloaded: {fn} -> {local_fn}")
                        continue
                    else:
                        # URL changed - could be server reset or actual new content
                        # Conservative approach: treat as new file to avoid missing updates
                        print(f"URL hash changed for {fn}, downloading as new file")
                else:
                    print(f"File missing locally, re-downloading: {fn}")
            
            # Extract number from remote filename to preserve numbering scheme
            # aligned_123.jpg -> use 123 as the local number
            try:
                base = os.path.splitext(fn)[0]
                remote_num = int(base.split('_')[1])
            except (ValueError, IndexError):
                # Fallback: if can't parse number, use next available
                remote_num = get_next_available_number(OUT_DIR)
            
            ext = os.path.splitext(fn)[1]
            new_name = f"aligned_{remote_num}{ext}"
            new_path = os.path.join(OUT_DIR, new_name)
            
            # Check if this exact local filename already exists (collision from different extension)
            if os.path.exists(new_path):
                print(f"Warning: {new_name} already exists, using next available number")
                new_name = f"aligned_{get_next_available_number(OUT_DIR)}{ext}"
                new_path = os.path.join(OUT_DIR, new_name)
            
            tasks.append((fn, new_name, url, new_path, url_hash))
            print(f"Queued: {fn} -> {new_name}")

        if not tasks:
            print("No new files to download")
            conn.close()
            return

        downloaded = 0
        with ThreadPoolExecutor(max_workers=workers) as ex:
            futures = {}
            for remote_fn, display_name, url, dest, url_hash in tasks:
                futures[ex.submit(download_file_requests, session, url, dest)] = (remote_fn, display_name, url_hash)
            
            for fut in as_completed(futures):
                remote_fn, display_name, url_hash = futures[fut]
                try:
                    ok = fut.result()
                    if ok:
                        print('Downloaded:', display_name)
                        # Record in database
                        cursor.execute('''
                            INSERT OR REPLACE INTO downloads (remote_filename, local_filename, url_hash)
                            VALUES (?, ?, ?)
                        ''', (remote_fn, display_name, url_hash))
                        conn.commit()
                        downloaded += 1
                    else:
                        print('Failed:', display_name)
                except Exception as e:
                    print('Exception downloading', display_name, ':', e)
        
        print(f'Done. Downloaded {downloaded} of {len(tasks)} files')
        conn.close()
        return

    except Exception as e:
        print('Parallel download failed, falling back to sequential:', e)

    # urllib fallback (sequential)
    downloaded = 0
    for it in items:
        fn = it.get('filename') if isinstance(it, dict) else None
        url = it.get('url') if isinstance(it, dict) else None
        if not fn or not url:
            continue
        
        # Skip non-image files
        fn_lower = fn.lower()
        if not fn_lower.startswith('aligned_') or not (fn_lower.endswith('.jpg') or fn_lower.endswith('.jpeg') or fn_lower.endswith('.png')):
            continue
        
        url_hash = hashlib.sha256(url.encode()).hexdigest()[:16]
        
        if fn in db_records:
            local_fn, stored_hash = db_records[fn]
            if stored_hash == url_hash and os.path.exists(os.path.join(OUT_DIR, local_fn)):
                continue
        
        # Use remote filename's number
        try:
            base = os.path.splitext(fn)[0]
            remote_num = int(base.split('_')[1])
        except (ValueError, IndexError):
            remote_num = get_next_available_number(OUT_DIR)
        
        ext = os.path.splitext(fn)[1]
        new_name = f"aligned_{remote_num}{ext}"
        new_path = os.path.join(OUT_DIR, new_name)
        
        if os.path.exists(new_path):
            new_name = f"aligned_{get_next_available_number(OUT_DIR)}{ext}"
            new_path = os.path.join(OUT_DIR, new_name)
        
        print('Downloading', new_name)
        try:
            download_file_urllib(url, new_path)
            cursor.execute('''
                INSERT OR REPLACE INTO downloads (remote_filename, local_filename, url_hash)
                VALUES (?, ?, ?)
            ''', (fn, new_name, url_hash))
            conn.commit()
            downloaded += 1
        except Exception as e:
            print('Failed to download', fn, ':', e)
    
    print(f'Done. Downloaded {downloaded} files')
    conn.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--workers', type=int, default=6, help='number of parallel download workers')
    args = parser.parse_args()
    main(workers=args.workers)
