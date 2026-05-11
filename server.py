import os
import time
import io
import zipfile
import cv2
import mediapipe as mp
import numpy as np
from pathlib import Path
from flask import Flask, request, send_from_directory, send_file, jsonify, abort


ROOT_DIR = Path(__file__).resolve().parent
UPLOAD_DIR = ROOT_DIR / "uploads"
FACES_DIR = ROOT_DIR / "faces"
UPLOAD_DIR.mkdir(exist_ok=True)
FACES_DIR.mkdir(exist_ok=True)

# Lazy initialize MediaPipe Face Mesh to avoid heavy initialization at import time
mp_face_mesh = mp.solutions.face_mesh
face_mesh = None

def get_face_mesh():
    """Create and return a singleton FaceMesh instance."""
    global face_mesh
    if face_mesh is None:
        face_mesh = mp_face_mesh.FaceMesh(static_image_mode=True, max_num_faces=1)
    return face_mesh

def get_landmarks(img):
    """Extract face landmarks from image using MediaPipe"""
    img_rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    fm = get_face_mesh()
    results = fm.process(img_rgb)
    if not results.multi_face_landmarks:
        return None
    landmarks = results.multi_face_landmarks[0].landmark
    h, w, _ = img.shape
    # Convert normalized coordinates to pixel coordinates
    points = np.array([(int(lm.x * w), int(lm.y * h)) for lm in landmarks], dtype=np.float32)
    return points

def align_face_to_reference(input_img_path, reference_img_path, output_path, lang='ja'):
    """Align input face to reference using similarity (no shear),
    fallback to full affine only if needed."""
    
    error_messages = {
        'ja': {
            'load_failed': '画像を読み込めませんでした',
            'no_face': '顔が検出されませんでした',
            'alignment_failed': '位置調整に失敗しました'
        },
        'en': {
            'load_failed': 'Could not load images',
            'no_face': 'Face not detected in one of the images',
            'alignment_failed': 'Alignment failed'
        }
    }
    msg = error_messages[lang]
    
    try:
        # Load images
        input_img = cv2.imread(str(input_img_path))
        reference_img = cv2.imread(str(reference_img_path))
        
        if input_img is None or reference_img is None:
            return False, msg['load_failed']
        
        # Get landmarks
        input_landmarks = get_landmarks(input_img)
        ref_landmarks = get_landmarks(reference_img)
        
        if input_landmarks is None or ref_landmarks is None:
            return False, msg['no_face']
        
        # Choose 3 key points: left eye, right eye, nose tip
        ref_pts = np.array([
            ref_landmarks[33],  # left eye corner
            ref_landmarks[263], # right eye corner
            ref_landmarks[1]    # nose tip
        ], dtype=np.float32)
        
        input_pts = np.array([
            input_landmarks[33],
            input_landmarks[263],
            input_landmarks[1]
        ], dtype=np.float32)
        
        # Prefer similarity transform (rotation + scale + translation, no shear)
        M, inliers = cv2.estimateAffinePartial2D(
            input_pts.reshape(-1, 1, 2),
            ref_pts.reshape(-1, 1, 2),
            method=cv2.RANSAC,
            ransacReprojThreshold=3.0,
            maxIters=2000,
            confidence=0.99,
            refineIters=10,
        )

        # Fallback to full affine only if partial estimation failed
        if M is None:
            M = cv2.getAffineTransform(input_pts, ref_pts)

        aligned_img = cv2.warpAffine(
            input_img,
            M,
            (reference_img.shape[1], reference_img.shape[0]),
            flags=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_REFLECT101,
        )
        
        # Save aligned image
        cv2.imwrite(str(output_path), aligned_img)
        return True, "Face aligned successfully"
        
    except Exception as e:
        return False, f"{msg['alignment_failed']}: {str(e)}"

app = Flask(
    __name__,
    static_folder=str(ROOT_DIR),
    static_url_path="",
)


@app.get("/")
def root():
    return send_from_directory(ROOT_DIR, "index.html")

@app.get("/jp/")
def japanese_page():
    return send_from_directory(ROOT_DIR / "jp", "index.html")

@app.get("/en/")
def english_page():
    return send_from_directory(ROOT_DIR / "en", "index.html")


@app.post("/upload")
def upload():
    # Detect language from Accept-Language header or referer
    lang = 'ja'
    referer = request.headers.get('Referer', '')
    if '/en/' in referer:
        lang = 'en'
    elif '/jp/' in referer:
        lang = 'ja'
    else:
        # Fallback to Accept-Language header
        accept_lang = request.headers.get('Accept-Language', '')
        if accept_lang and not accept_lang.startswith('ja'):
            lang = 'en'
    
    messages = {
        'ja': {
            'no_image': '画像ファイルが見つかりません',
            'empty_filename': 'ファイル名が空です',
            'upload_failed': 'アップロードに失敗しました',
            'face_aligned': '写真がアップロードされ、顔の位置が調整されました',
            'alignment_failed': '写真はアップロードされましたが、顔の位置調整に失敗しました',
            'upload_success': '写真が正常にアップロードされました'
        },
        'en': {
            'no_image': 'No image file found',
            'empty_filename': 'Empty filename',
            'upload_failed': 'Upload failed',
            'face_aligned': 'Photo uploaded and face aligned successfully',
            'alignment_failed': 'Photo uploaded but face alignment failed',
            'upload_success': 'Photo uploaded successfully'
        }
    }
    msg = messages[lang]
    
    try:
        # Expecting multipart/form-data with field name 'image'
        if "image" not in request.files:
            return jsonify({"status": "error", "message": msg['no_image']}), 400

        file = request.files["image"]
        if file.filename == "":
            return jsonify({"status": "error", "message": msg['empty_filename']}), 400

        # Basic filename sanitation and unique naming
        name, ext = os.path.splitext(file.filename)
        ext = ext.lower() if ext else ".jpg"
        ts = int(time.time() * 1000)
        safe_name = f"upload_{ts}{ext}"
        save_path = UPLOAD_DIR / safe_name
        file.save(save_path)
        
        print(f"Saved uploaded file to: {save_path}")
    except Exception as e:
        return jsonify({"status": "error", "message": f"{msg['upload_failed']}: {str(e)}"}), 500

    # Try to align face if reference image exists
    reference_path = ROOT_DIR / "reference.jpg"
    if reference_path.exists():
        print(f"Reference image found at: {reference_path}")
        
        # Find the next sequential number for aligned faces
        existing_aligned = [
            f for f in FACES_DIR.iterdir() 
            if f.is_file() and f.name.lower().startswith("aligned_")
        ]
        max_num = 0
        for f in existing_aligned:
            try:
                # Extract number from aligned_N.ext
                num_str = f.stem.split('_')[1]  # e.g., "aligned_123" -> "123"
                num = int(num_str)
                max_num = max(max_num, num)
            except (ValueError, IndexError):
                pass  # Skip files that don't match the pattern
        
        next_num = max_num + 1
        aligned_name = f"aligned_{next_num}{ext}"
        aligned_path = FACES_DIR / aligned_name
        success, message = align_face_to_reference(save_path, reference_path, aligned_path, lang)
        
        if success:
            print(f"Face alignment successful: {aligned_path}")
            return jsonify({
                "status": "ok",
                "filename": safe_name,
                "path": f"/uploads/{safe_name}",
                "aligned_filename": aligned_name,
                "aligned_path": f"/faces/{aligned_name}",
                "message": msg['face_aligned']
            })
        else:
            print(f"Face alignment failed: {message}")
            return jsonify({
                "status": "warning",
                "filename": safe_name,
                "path": f"/uploads/{safe_name}",
                "message": f"{msg['alignment_failed']}: {message}"
            })
    else:
        print("No reference image found, skipping alignment")
        return jsonify({
            "status": "ok",
            "filename": safe_name,
            "path": f"/uploads/{safe_name}",
            "message": msg['upload_success']
        })


@app.get("/uploads/<path:filename>")
def get_upload(filename: str):
    return send_from_directory(UPLOAD_DIR, filename)


@app.get("/faces/<path:filename>")
def get_face(filename: str):
    return send_from_directory(FACES_DIR, filename)


@app.get('/faces')
def list_faces():
    """Return a JSON list of aligned face filenames and their public URLs."""
    try:
        files = sorted([p.name for p in FACES_DIR.iterdir() if p.is_file()])
        base = request.url_root.rstrip('/')
        items = [{
            'filename': name,
            'url': f"{base}/faces/{name}"
        } for name in files]
        return jsonify(items)
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)}), 500


@app.get('/faces/download_all')
def download_all_faces():
    """Return a ZIP archive containing all aligned face files."""
    try:
        files = [p for p in FACES_DIR.iterdir() if p.is_file()]
        if not files:
            return jsonify({'status': 'error', 'message': 'No face files found'}), 404

        mem = io.BytesIO()
        with zipfile.ZipFile(mem, mode='w', compression=zipfile.ZIP_DEFLATED) as zf:
            for p in files:
                zf.write(p, arcname=p.name)
        mem.seek(0)
        return send_file(mem, mimetype='application/zip', as_attachment=True, download_name='faces.zip')
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)}), 500


if __name__ == "__main__":
    # For local dev you can enable debug by setting FLASK_DEBUG=1 in the env.
    port = int(os.environ.get("PORT", "8000"))
    debug = os.environ.get("FLASK_DEBUG", "0") == "1"
    app.run(host="0.0.0.0", port=port, debug=debug)


