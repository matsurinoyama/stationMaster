#!/usr/bin/env python3
"""
Quick utility to inspect the SQLite database and see what's been tracked.
Usage: python3 inspect_db.py
"""
import os
import sqlite3
from datetime import datetime

BASE_DIR = os.path.dirname(__file__)
OUT_DIR = os.path.normpath(os.path.join(BASE_DIR, '..', 'faces'))
DB_PATH = os.path.join(OUT_DIR, '.faces_db.sqlite')

def main():
    if not os.path.exists(DB_PATH):
        print(f"Database not found at: {DB_PATH}")
        print("Run download_faces.py first to create it.")
        return
    
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    # Get total count
    cursor.execute('SELECT COUNT(*) FROM downloads')
    total = cursor.fetchone()[0]
    
    print(f"\n{'='*60}")
    print(f"Database: {DB_PATH}")
    print(f"Total tracked downloads: {total}")
    print(f"{'='*60}\n")
    
    if total == 0:
        print("No downloads tracked yet.")
        conn.close()
        return
    
    # Get all records
    cursor.execute('''
        SELECT remote_filename, local_filename, url_hash, downloaded_at 
        FROM downloads 
        ORDER BY downloaded_at DESC
    ''')
    
    print(f"{'Remote Filename':<20} {'Local Filename':<20} {'URL Hash':<18} {'Downloaded'}")
    print('-' * 90)
    
    for row in cursor.fetchall():
        remote_fn, local_fn, url_hash, timestamp = row
        # Format timestamp if it exists
        try:
            dt = datetime.fromisoformat(timestamp)
            time_str = dt.strftime('%Y-%m-%d %H:%M')
        except:
            time_str = timestamp or 'unknown'
        
        print(f"{remote_fn:<20} {local_fn:<20} {url_hash:<18} {time_str}")
    
    print()
    
    # Check for files that exist in DB but not on disk
    cursor.execute('SELECT local_filename FROM downloads')
    missing = []
    for row in cursor.fetchall():
        local_fn = row[0]
        if not os.path.exists(os.path.join(OUT_DIR, local_fn)):
            missing.append(local_fn)
    
    if missing:
        print(f"\n⚠️  Warning: {len(missing)} files in database but missing from disk:")
        for fn in missing[:10]:  # Show first 10
            print(f"  - {fn}")
        if len(missing) > 10:
            print(f"  ... and {len(missing) - 10} more")
    else:
        print("✓ All tracked files exist on disk")
    
    conn.close()
    print()

if __name__ == '__main__':
    main()
