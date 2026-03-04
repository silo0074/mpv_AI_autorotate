
import sys, site, os

# --- CONFIG ---
SOCKET_PATH = '/tmp/mpv_ai_socket'
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MODEL_PATH = os.path.join(SCRIPT_DIR, 'orientation_model_v2_0.9882.onnx')
VENV_PATH = os.path.join(SCRIPT_DIR, 'env/lib/python3.13/site-packages')
INI_BASE_PATH = os.path.expanduser("~/.config/smplayer/file_settings/")
site.addsitedir(VENV_PATH)

import numpy as np
import cv2
import onnxruntime as ort
import socket
import struct
import signal
from collections import deque

history = deque(maxlen=5)

# Define the options object
# Create session options to use multiple threads (faster CPU processing)
options = ort.SessionOptions()
# Use 4 threads to match physical cores
options.intra_op_num_threads = 4
# Sequential mode is often more stable for single-stream video processing
options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL

# OpenVINO specific GPU optimizations
provider_options = [{
    'device_type': 'GPU',
    'cache_dir': '/tmp/ov_cache', # Saves compiled model to prevent Broken Pipe on startup
    'num_streams': '1'            # Best for latency in 4-second interval checks
}]


try:
    # REMOVE CUDA for a moment to verify stability
    # Use 'CPUExecutionProvider' with internal optimizations
    # session = ort.InferenceSession(
    #     MODEL_PATH,
    #     # sess_options=options,
    #     providers=['OpenVINOExecutionProvider']
    # )

    session = ort.InferenceSession(
        MODEL_PATH,
        sess_options=options,
        providers=['OpenVINOExecutionProvider'],
        provider_options=provider_options
    ) # Forces Intel iGPU

    input_name = session.get_inputs()[0].name
    sys.stderr.write(f"\n--- AI ACTIVE ON: {session.get_providers()[0]} ---")
except Exception as e:
    sys.stderr.write(f"\nAI LOAD ERROR: {e}")
    sys.exit(1)


def get_smplayer_hash(filename):
    """Calculates the 64-bit MD5-like hash used by SMPlayer/OpenSubtitles."""
    try:
        size = os.path.getsize(filename)
        longlongformat = '<q'
        bytesize = struct.calcsize(longlongformat)

        with open(filename, "rb") as f:
            hash_val = size
            # Hash first 64KB
            for _ in range(65536 // bytesize):
                buffer = f.read(bytesize)
                (l_value,) = struct.unpack(longlongformat, buffer)
                hash_val = (hash_val + l_value) & 0xFFFFFFFFFFFFFFFF

            # Hash last 64KB
            f.seek(max(0, size - 65536), 0)
            for _ in range(65536 // bytesize):
                buffer = f.read(bytesize)
                (l_value,) = struct.unpack(longlongformat, buffer)
                hash_val = (hash_val + l_value) & 0xFFFFFFFFFFFFFFFF

        return "%016x" % hash_val
    except: return None


def get_ini_rotation(filename):
    """Finds the .ini and extracts the 'rotate=' value."""
    h = get_smplayer_hash(filename)
    if not h: return "0"

    # Path is: base / first_char_of_hash / hash.ini
    ini_path = os.path.join(INI_BASE_PATH, h[0], f"{h}.ini")

    if os.path.exists(ini_path):
        with open(ini_path, "r") as f:
            for line in f:
                if line.startswith("rotate="):
                    # SMPlayer: 0=0, 1=90, 2=180, 3=270
                    val = line.strip().split("=")[1]
                    mapping = {"0": "0", "1": "90", "2": "180", "3": "270"}
                    return mapping.get(val, "0")
    return "0"


def get_stable_prediction(header_bytes):
    try:
        header = header_bytes.decode('ascii').strip()
        w = int(header[:8])
        h = int(header[8:16])

        with open("/tmp/mpv_frame.raw", "rb") as f:
            raw_pixels = f.read()

        # DYNAMIC STRIDE CALCULATION
        # This works for any resolution (1080p, 4K, etc.)
        total_size = len(raw_pixels)
        stride_bytes = total_size // h
        channels = stride_bytes // w

        # Reshape to rows x stride
        img = np.frombuffer(raw_pixels, dtype=np.uint8).reshape((h, stride_bytes))

        # Check average brightness (0-255)
        # brightness = np.mean(img)
        # if brightness < 20: # If it's a dark/black frame
        #     print("\nSOCKET: Brightness under threshold. Returning.")
        #     return "0"     # Return a "do nothing" code

        # Crop out the padding bytes and reshape to proper HWC
        img = img[:, :w * channels].reshape((h, w, channels))

        # Convert to Numpy (RGB)
        # Handle 4-channel (BGR0) or 3-channel (BGR)
        if channels == 4:
            img = cv2.cvtColor(img[:, :, :3], cv2.COLOR_BGR2RGB)
        else:
            img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)

        # Center Crop to Square (to remove black bars/UI)
        h_orig, w_orig = img.shape[:2]
        min_side = min(h_orig, w_orig)
        start_x = (w_orig - min_side) // 2
        start_y = (h_orig - min_side) // 2
        img_cropped = img[start_y:start_y+min_side, start_x:start_x+min_side]

        # Preprocessing
        # Mean/Std Normalization
        img_resized = cv2.resize(img_cropped, (384, 384), interpolation=cv2.INTER_AREA).transpose(2, 0, 1).astype(np.float32) / 255.0
        # img_resized = cv2.resize(img_cropped, (384, 384)).transpose(2, 0, 1).astype(np.float32) / 255.0
        mean = np.array([0.485, 0.456, 0.406]).reshape(3, 1, 1)
        std = np.array([0.229, 0.224, 0.225]).reshape(3, 1, 1)
        img_final = np.expand_dims((img_resized - mean) / std, axis=0).astype(np.float32)

        # Inference
        raw_res = session.run(None, {input_name: img_final})[0][0]
        current_idx = int(np.argmax(raw_res))

        # Get probabilities (Softmax)
        probs = np.exp(raw_res) / np.sum(np.exp(raw_res))
        conf = np.max(probs)

        # Stability Vote
        history.append(current_idx)
        stable_idx = max(set(history), key=history.count)

        # Debugging info
        print(f"\nSOCKET: Res: {w}x{h} | Channels: {channels} | AI IDX: {current_idx}")
        print(f"\nSOCKET: Prediction Confidence: {conf}%")

        # Only return a rotation if the AI is 85% sure
        if conf < 0.90:
            print("\nSOCKET: Prediction Confidence under threshold. Returning.")
            return "0"

        return str(stable_idx)

    except Exception as e:
        print(f"\nSOCKET: Prediction Error: {e}")
        return "0"


# Cleanup on exit
def cleanup(signum, frame):
    print("\nSOCKET: AI Listener shutting down...")
    try:
        if os.path.exists(SOCKET_PATH):
            os.remove(SOCKET_PATH)
    except OSError:
        pass # Already deleted by mpv/Lua

    try:
        if os.path.exists("/tmp/mpv_frame.raw"):
            os.remove("/tmp/mpv_frame.raw")
    except OSError:
        pass
    sys.exit(0)

# Apply to signals
signal.signal(signal.SIGTERM, cleanup)
signal.signal(signal.SIGINT, cleanup)


# Socket Logic
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
if os.path.exists(SOCKET_PATH): os.remove(SOCKET_PATH)
server.bind(SOCKET_PATH)
# Allows the operating system to queue up requests
# from multiple mpv windows if they happen at the same time.
server.listen(5)

print("\nSOCKET: AI Listener with SMPlayer Hash Support Active...")

# refine the Python while loop to handle multiple simultaneous mpv connections using threads?
while True:
    conn, _ = server.accept()
    try:
        data = conn.recv(4096) # Increased buffer to catch file paths
        if not data: continue

        msg = data.decode('utf-8', errors='ignore').strip()
        print(f"\nSOCKET: Received message: {msg}")

        # COMMAND TYPE 1: Hash Lookup (Starts with "PATH:")
        if msg.startswith("PATH:"):
            print("\nSOCKET: Type 1 cmd")
            file_path = msg[5:]
            rotation = get_ini_rotation(file_path)
            conn.sendall(rotation.encode())


        # COMMAND TYPE 2: AI Orientation (The 16-byte numeric header)
        elif len(msg) == 16 and msg.isdigit():
            print("\nSOCKET: Type 2 cmd")
            result = get_stable_prediction(data)
            conn.sendall(result.encode())

        conn.shutdown(socket.SHUT_WR)
        # Small sleep (10ms) to ensure the pipe stays open for the client to read
        import time
        time.sleep(0.01)

    except Exception as e:
        print(f"\nSOCKET: Socket Error: {e}")
    finally:
        print("\nSOCKET: conn.close")
        conn.close()
