import cv2
import mediapipe as mp
import numpy as np

# Setup
cap = cv2.VideoCapture(0)
mp_face_mesh = mp.solutions.face_mesh
face_mesh = mp_face_mesh.FaceMesh(refine_landmarks=True)
TEMPLATE_SIZE = (512, 768)

def is_face_forward(landmarks, w, h, tol=0.1, roll_tol=0.1, pitch_tol=0.08):
    """
    Check if face is facing forward (yaw + roll + pitch).
    """

    # Landmarks
    nose_bottom = landmarks[2]   # bottom of nose
    left_eye = landmarks[33]     # left eye corner
    right_eye = landmarks[263]   # right eye corner

    # Convert to pixels
    nb_x, nb_y = nose_bottom.x * w, nose_bottom.y * h
    le_x, le_y = left_eye.x * w, left_eye.y * h
    re_x, re_y = right_eye.x * w, right_eye.y * h

    # ---- YAW CHECK ----
    eye_mid_x = (le_x + re_x) / 2
    offset = abs(nb_x - eye_mid_x) / (re_x - le_x)
    yaw_ok = offset < tol

    # ---- ROLL CHECK ----
    dx = re_x - le_x
    dy = re_y - le_y
    slope = abs(dy / dx) if dx != 0 else 999
    roll_ok = slope < roll_tol

    # ---- PITCH CHECK ----
    eye_mid_y = (le_y + re_y) / 2
    eye_dist = ((re_x - le_x) ** 2 + (re_y - le_y) ** 2) ** 0.5

    vertical_offset = (nb_y - eye_mid_y) / eye_dist

    pitch_baseline = 0.53
    pitch_ok = abs(vertical_offset - pitch_baseline) < pitch_tol

    return yaw_ok and roll_ok and pitch_ok


while True:
    ret, frame = cap.read()
    if not ret:
        break

    # Mirror the webcam feed horizontally
    frame = cv2.flip(frame, 1)

    # Convert to RGB for face mesh processing
    rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    results = face_mesh.process(rgb)

    if results.multi_face_landmarks:
        for face_landmarks in results.multi_face_landmarks:
            h, w, _ = frame.shape

            if is_face_forward(face_landmarks.landmark, w, h):
                cv2.putText(frame, "Facing Forward ✅", (30, 30),
                            cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 255, 0), 2)
            else:
                cv2.putText(frame, "Turn face to camera ❌", (30, 30),
                            cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 0, 255), 2)

    cv2.imshow("Live Webcam (SPACE to capture, Q to quit)", frame)

    key = cv2.waitKey(1) & 0xFF
    if key == ord(' '):  # capture only if forward
        if results.multi_face_landmarks:
            face_landmarks = results.multi_face_landmarks[0]
            if is_face_forward(face_landmarks.landmark, w, h):
                # Get bbox from landmarks
                xs = [lm.x * w for lm in face_landmarks.landmark]
                ys = [lm.y * h for lm in face_landmarks.landmark]
                x_min, x_max = int(min(xs)), int(max(xs))
                y_min, y_max = int(min(ys)), int(max(ys))

                face_crop = frame[y_min:y_max, x_min:x_max]

                # Flip the captured face horizontally to match the mirrored view
                face_crop = cv2.flip(face_crop, 1)

                # face_resized = cv2.resize(face_crop, TEMPLATE_SIZE)
                # cv2.imshow("Captured Face", face_resized)
                cv2.imwrite("captured_face.jpg", face_crop)
                print("✅ Face captured and saved as captured_face.jpg")
            else:
                print("⚠️ Face not forward — capture blocked.")

    elif key == ord('q'):
        break

cap.release()
cv2.destroyAllWindows()
