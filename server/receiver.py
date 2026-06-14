import os
import time
import zipfile
import json
from flask import Flask, request, jsonify, send_from_directory

app = Flask(__name__)

# Config
UPLOAD_DIR = "/data/seize_captures"
STATUS_FILE = "/dev/shm/seize_status.json"  # Using RAM disk to protect SD card

# Ensure directories exist
os.makedirs(UPLOAD_DIR, exist_ok=True)

DEFAULT_STATUS = {
    "state": "IDLE",            # IDLE, CONNECTED, EXTRACTING, SAVING, COMPLETED, FAILED
    "hostname": "N/A",
    "os": "N/A",
    "current_task": "Waiting for target...",
    "percent": 0,
    "bytes_received": 0,
    "bytes_total": 0,
    "timestamp": None,
    "elapsed_time": "0s",
    "saved_path": "",
    "error_message": ""
}

def load_status():
    try:
        if os.path.exists(STATUS_FILE):
            with open(STATUS_FILE, 'r') as f:
                return json.load(f)
    except Exception:
        pass
    return DEFAULT_STATUS.copy()

def save_status(status):
    try:
        # Ensure directory exists (should be /dev/shm which is standard on RPi)
        os.makedirs(os.path.dirname(STATUS_FILE), exist_ok=True)
        with open(STATUS_FILE, 'w') as f:
            json.dump(status, f)
    except Exception as e:
        print(f"Error saving status: {e}")

# Initialize status
save_status(DEFAULT_STATUS)

@app.route('/api/status', methods=['GET'])
def get_status():
    return jsonify(load_status())

@app.route('/api/start', methods=['POST'])
def start_capture():
    data = request.json or {}
    status = DEFAULT_STATUS.copy()
    status["state"] = "CONNECTED"
    status["hostname"] = data.get("hostname", "UNKNOWN")
    status["os"] = data.get("os", "UNKNOWN")
    status["current_task"] = "Connection established. Beginning triage..."
    status["percent"] = 5
    status["timestamp"] = time.strftime("%Y-%m-%d %H:%M:%S")
    status["start_time"] = time.time()
    save_status(status)
    return jsonify({"status": "started"})

@app.route('/api/progress', methods=['POST'])
def update_progress():
    data = request.json or {}
    status = load_status()
    if status["state"] not in ["CONNECTED", "EXTRACTING"]:
        status["state"] = "EXTRACTING"
        
    status["current_task"] = data.get("task", status["current_task"])
    status["percent"] = int(data.get("percent", status["percent"]))
    
    # Calculate elapsed time
    start_time = status.get("start_time")
    if start_time:
        elapsed = int(time.time() - start_time)
        status["elapsed_time"] = f"{elapsed}s"
        
    save_status(status)
    return jsonify({"status": "updated"})

@app.route('/api/upload', methods=['POST'])
def upload_file():
    status = load_status()
    status["state"] = "SAVING"
    status["current_task"] = "Transferring data to Pi..."
    status["percent"] = 90
    save_status(status)
    
    if 'file' not in request.files:
        status["state"] = "FAILED"
        status["error_message"] = "No file part in upload request"
        save_status(status)
        return jsonify({"error": "No file part"}), 400
        
    file = request.files['file']
    if file.filename == '':
        status["state"] = "FAILED"
        status["error_message"] = "No file selected"
        save_status(status)
        return jsonify({"error": "No selected file"}), 400

    hostname = status.get("hostname", "UNKNOWN_DEVICE").replace(" ", "_")
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    capture_folder_name = f"{hostname}_{timestamp}"
    target_dir = os.path.join(UPLOAD_DIR, capture_folder_name)
    os.makedirs(target_dir, exist_ok=True)
    
    zip_path = os.path.join(target_dir, "capture.zip")
    
    try:
        # Save zip file
        file.save(zip_path)
        status["bytes_received"] = os.path.getsize(zip_path)
        
        # Unzip files to keep them unencrypted as requested
        status["current_task"] = "Extracting forensic evidence..."
        save_status(status)
        
        with zipfile.ZipFile(zip_path, 'r') as zip_ref:
            zip_ref.extractall(target_dir)
            
        # Clean up the zip file to leave only the unencrypted directories
        os.remove(zip_path)
        
        # Finalize status
        status["state"] = "COMPLETED"
        status["current_task"] = "Extraction finished successfully."
        status["percent"] = 100
        status["saved_path"] = target_dir
        
        start_time = status.get("start_time")
        if start_time:
            elapsed = int(time.time() - start_time)
            status["elapsed_time"] = f"{elapsed}s"
            
        save_status(status)
        print(f"Data saved and extracted to: {target_dir}")
        return jsonify({"status": "success", "path": target_dir})
        
    except Exception as e:
        status["state"] = "FAILED"
        status["error_message"] = str(e)
        save_status(status)
        return jsonify({"error": str(e)}), 500

@app.route('/api/error', methods=['POST'])
def capture_error():
    data = request.json or {}
    status = load_status()
    status["state"] = "FAILED"
    status["current_task"] = "Error encountered during extraction."
    status["error_message"] = data.get("message", "Unknown error")
    save_status(status)
    return jsonify({"status": "error_logged"})

@app.route('/api/reset', methods=['POST'])
def reset_status():
    save_status(DEFAULT_STATUS)
    return jsonify({"status": "reset"})

@app.route('/payloads/<path:filename>', methods=['GET'])
def serve_payloads(filename):
    # Payload directory is /opt/seize/payloads when deployed on Pi
    payloads_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '../payloads'))
    if not os.path.exists(payloads_dir):
        payloads_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), 'payloads'))
    return send_from_directory(payloads_dir, filename)

if __name__ == '__main__':
    # Running on port 5000, visible to the USB subnet
    app.run(host='0.0.0.0', port=5000, debug=False)
