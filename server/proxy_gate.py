import os
import time
import json
import requests
from flask import Flask, request, jsonify, send_from_directory

app = Flask(__name__)

# Config
LOCAL_UPLOAD_DIR = "/data/seize_captures"
STATUS_FILE = "/dev/shm/seize_status.json"

# CENTRAL SERVER CONFIG (Update this with the actual IP address of your server computer)
SERVER_CONFIG_FILE = "/opt/seize/config/server_ip.txt"
DEFAULT_SERVER_IP = "192.168.1.100"  # Fallback IP

os.makedirs(LOCAL_UPLOAD_DIR, exist_ok=True)

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
    "error_message": "",
    "server_sync": "OFFLINE"   # OFFLINE, PENDING, SYNCED, FAILED
}

def get_server_ip():
    if os.path.exists(SERVER_CONFIG_FILE):
        try:
            with open(SERVER_CONFIG_FILE, 'r') as f:
                ip = f.read().strip()
                if ip:
                    return ip
        except Exception:
            pass
    return DEFAULT_SERVER_IP

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
        os.makedirs(os.path.dirname(STATUS_FILE), exist_ok=True)
        with open(STATUS_FILE, 'w') as f:
            json.dump(status, f)
    except Exception as e:
        print(f"Error saving status: {e}")

# Initialize status
save_status(DEFAULT_STATUS)

@app.route('/api/status', methods=['GET'])
def get_status():
    status = load_status()
    # Add server IP info for debugging
    status["server_ip"] = get_server_ip()
    return jsonify(status)

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
    capture_filename = f"{hostname}_{timestamp}.zip"
    
    local_zip_path = os.path.join(LOCAL_UPLOAD_DIR, capture_filename)
    
    try:
        # Save zip file locally on the Pi SD card as cache/backup
        file.save(local_zip_path)
        status["bytes_received"] = os.path.getsize(local_zip_path)
        
        # Update state: Attempting to upload to central server
        server_ip = get_server_ip()
        server_url = f"http://{server_ip}:5000/api/upload_central"
        
        status["current_task"] = f"Syncing to server: {server_ip}..."
        status["server_sync"] = "PENDING"
        save_status(status)
        
        # Forward the zip file to the central server computer
        try:
            with open(local_zip_path, 'rb') as f:
                files = {'file': (capture_filename, f, 'application/zip')}
                # Forward metadata headers
                headers = {
                    'X-SEIZE-Hostname': status.get("hostname", "UNKNOWN"),
                    'X-SEIZE-OS': status.get("os", "UNKNOWN")
                }
                response = requests.post(server_url, files=files, headers=headers, timeout=120)
                
            if response.status_code == 200:
                status["server_sync"] = "SYNCED"
                status["state"] = "COMPLETED"
                status["current_task"] = "Extraction & Server Sync complete."
                status["percent"] = 100
                
                # Delete local backup to conserve space on SD card, if sync was successful
                # (Optional: Comment this line out if you want to keep a copy on the Pi Zero too)
                os.remove(local_zip_path)
            else:
                raise Exception(f"Server returned status code {response.status_code}")
                
        except Exception as sync_err:
            # Sync failed (e.g. server computer is offline or network is down)
            print(f"Sync error: {sync_err}")
            status["server_sync"] = "FAILED"
            status["state"] = "COMPLETED"
            status["current_task"] = "Offline backup saved to Pi SD card."
            status["percent"] = 100
            
        start_time = status.get("start_time")
        if start_time:
            elapsed = int(time.time() - start_time)
            status["elapsed_time"] = f"{elapsed}s"
            
        save_status(status)
        return jsonify({"status": "success", "sync": status["server_sync"]})
        
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
    payloads_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '../payloads'))
    if not os.path.exists(payloads_dir):
        payloads_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), 'payloads'))
    return send_from_directory(payloads_dir, filename)

if __name__ == '__main__':
    # Running on local RPi port 5000, listening on RNDIS subnet
    app.run(host='0.0.0.0', port=5000, debug=False)
