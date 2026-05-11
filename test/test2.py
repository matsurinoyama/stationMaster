import cv2
import mediapipe as mp
import numpy as np

mp_face_mesh = mp.solutions.face_mesh

# Initialize Face Mesh
face_mesh = mp_face_mesh.FaceMesh(static_image_mode=True)

def get_landmarks(img):
    img_rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    results = face_mesh.process(img_rgb)
    if not results.multi_face_landmarks:
        return None
    landmarks = results.multi_face_landmarks[0].landmark
    h, w, _ = img.shape
    # Convert normalized coordinates to pixel coordinates
    points = np.array([(int(lm.x * w), int(lm.y * h)) for lm in landmarks], dtype=np.float32)
    return points

# Load images
reference_img = cv2.imread("reference.jpg")
captured_img = cv2.imread("captured.jpg")

ref_landmarks = get_landmarks(reference_img)
cap_landmarks = get_landmarks(captured_img)

if ref_landmarks is None or cap_landmarks is None:
    print("Face not detected in one of the images")
    exit()

# Choose 3 key points: left eye, right eye, nose tip
ref_pts = np.array([
    ref_landmarks[33],  # left eye corner
    ref_landmarks[263], # right eye corner
    ref_landmarks[1]    # nose tip
], dtype=np.float32)

cap_pts = np.array([
    cap_landmarks[33],
    cap_landmarks[263],
    cap_landmarks[1]
], dtype=np.float32)

# Compute affine transform
M = cv2.getAffineTransform(cap_pts, ref_pts)

# Apply affine transform
aligned_img = cv2.warpAffine(captured_img, M, (reference_img.shape[1], reference_img.shape[0]))

# Show results
cv2.imshow("Reference", reference_img)
cv2.imshow("Captured", captured_img)
cv2.imshow("Aligned", aligned_img)
cv2.waitKey(0)
cv2.destroyAllWindows()
