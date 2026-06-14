#!/bin/bash
# S.E.I.Z.E. (Swift Electronic Ingestion & Zero-delay Extraction)
# Forensic Extraction Script for Linux and macOS Targets
# Designed for Nepal Police Digital Forensics

# Exit on intermediate command error (we want to try everything anyway, so keep going)
# but run in a structured way.

# Configuration
SERVER_IP="192.168.7.1"
SERVER_PORT="5000"
BASE_URL="http://${SERVER_IP}:${SERVER_PORT}/api"
TEMP_DIR="/tmp/seize_triage"
ZIP_PATH="/tmp/seize_extraction.zip"

# Helper: Send status updates to S.E.I.Z.E. Pi Server
send_status() {
    local task="$1"
    local percent="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -s -X POST -H "Content-Type: application/json" \
            -d "{\"task\":\"$task\",\"percent\":$percent}" \
            "${BASE_URL}/progress" >/dev/null &
    fi
}

# Helper: Send errors to Pi
send_error() {
    local msg="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -s -X POST -H "Content-Type: application/json" \
            -d "{\"message\":\"$msg\"}" \
            "${BASE_URL}/error" >/dev/null &
    fi
}

# Detect OS
OS_TYPE="Linux"
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS_TYPE="macOS"
fi

HOSTNAME=$(hostname)

echo "[*] Starting S.E.I.Z.E. Forensic Extraction..."
echo "[*] Target OS: ${OS_TYPE} | Hostname: ${HOSTNAME}"

# Initialize connection
if command -v curl >/dev/null 2>&1; then
    curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"hostname\":\"$HOSTNAME\",\"os\":\"$OS_TYPE\"}" \
        "${BASE_URL}/start" >/dev/null
    echo "[+] Handshake sent to S.E.I.Z.E. Pi Server."
else
    echo "[!] Error: curl is required to run this script."
    exit 1
fi

# Clean & create temp directory
rm -rf "$TEMP_DIR" "$ZIP_PATH"
mkdir -p "$TEMP_DIR/browsers"
mkdir -p "$TEMP_DIR/volatile_ram"

# 1. Volatile RAM & System Triage
send_status "Extracting System Metadata..." 15
echo "[*] Collecting system info..."

SYS_INFO_FILE="$TEMP_DIR/volatile_ram/system_info.txt"
{
    echo "--- S.E.I.Z.E. SYSTEM REPORT ---"
    echo "Hostname: $HOSTNAME"
    echo "OS Type: $OS_TYPE"
    echo "Kernel: $(uname -a)"
    echo "Uptime: $(uptime)"
    echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Logged-in Users:"
    who
    echo "------------------------"
    echo "Environment Variables:"
    env
} > "$SYS_INFO_FILE"

send_status "Dumping active processes..." 25
echo "[*] Collecting process list..."
ps aux > "$TEMP_DIR/volatile_ram/processes.txt" 2>/dev/null

send_status "Collecting network connections..." 35
echo "[*] Collecting network connections..."
NET_CONN_FILE="$TEMP_DIR/volatile_ram/network_connections.txt"
if [ "$OS_TYPE" = "macOS" ]; then
    netstat -an > "$NET_CONN_FILE" 2>/dev/null
    lsof -i >> "$NET_CONN_FILE" 2>/dev/null
else
    ss -tulpn > "$NET_CONN_FILE" 2>/dev/null || netstat -antp >> "$NET_CONN_FILE" 2>/dev/null
fi

# Clipboard (Volatile RAM)
echo "[*] Extracting clipboard contents..."
CLIP_FILE="$TEMP_DIR/volatile_ram/clipboard.txt"
if [ "$OS_TYPE" = "macOS" ]; then
    pbpaste > "$CLIP_FILE" 2>/dev/null
else
    if command -v xclip >/dev/null 2>&1; then
        xclip -selection clipboard -o > "$CLIP_FILE" 2>/dev/null
    elif command -v xsel >/dev/null 2>&1; then
        xsel -b -o > "$CLIP_FILE" 2>/dev/null
    else
        echo "Clipboard extraction tools (xclip/xsel) not installed." > "$CLIP_FILE"
    fi
fi

# DNS Cache & ARP Table
echo "[*] Collecting DNS cache & ARP table..."
arp -a > "$TEMP_DIR/volatile_ram/arp_table.txt" 2>/dev/null
if [ "$OS_TYPE" = "macOS" ]; then
    dscacheutil -cachedump -entries Host > "$TEMP_DIR/volatile_ram/dns_cache.txt" 2>/dev/null
else
    resolvectl statistics > "$TEMP_DIR/volatile_ram/dns_cache.txt" 2>/dev/null || ip neigh >> "$TEMP_DIR/volatile_ram/dns_cache.txt" 2>/dev/null
fi

# Wi-Fi profiles if root
echo "[*] Collecting Wi-Fi profiles..."
WIFI_FILE="$TEMP_DIR/volatile_ram/wifi_profiles.txt"
if [ "$OS_TYPE" = "macOS" ]; then
    networksetup -listallhardwareports > "$WIFI_FILE" 2>/dev/null
else
    if [ "$EUID" -eq 0 ]; then
        ls -la /etc/NetworkManager/system-connections/ > "$WIFI_FILE" 2>/dev/null
        cat /etc/NetworkManager/system-connections/* >> "$WIFI_FILE" 2>/dev/null
    else
        echo "Root access required to view Linux Wi-Fi configs." > "$WIFI_FILE"
    fi
fi

# 2. Browser History & Cache Ingestion
send_status "Locating Browser Histories..." 45
echo "[*] Ingesting browser histories..."

copy_chromium_data() {
    local b_name="$1"
    local b_hist="$2"
    local b_cache="$3"
    
    # Expand tilde path
    b_hist="${b_hist/#\~/$HOME}"
    b_cache="${b_cache/#\~/$HOME}"
    
    if [ -f "$b_hist" ]; then
        echo "[+] Found $b_name history"
        send_status "Extracting $b_name History..." 55
        mkdir -p "$TEMP_DIR/browsers/$b_name"
        cp "$b_hist" "$TEMP_DIR/browsers/$b_name/History.db"
        
        if [ -d "$b_cache" ]; then
            send_status "Extracting $b_name Cache..." 65
            mkdir -p "$TEMP_DIR/browsers/$b_name/Cache"
            # Copy small cache indexes and descriptors, excluding massive files
            find "$b_cache" -type f -size -5M -exec cp {} "$TEMP_DIR/browsers/$b_name/Cache/" \; 2>/dev/null
        fi
    fi
}

if [ "$OS_TYPE" = "macOS" ]; then
    # macOS Chromium-based browsers
    copy_chromium_data "Chrome" "~/Library/Application Support/Google/Chrome/Default/History" "~/Library/Caches/Google/Chrome/Default/Cache"
    copy_chromium_data "Edge" "~/Library/Application Support/Microsoft Edge/Default/History" "~/Library/Caches/Microsoft Edge/Default/Cache"
    copy_chromium_data "Brave" "~/Library/Application Support/BraveSoftware/Brave-Browser/Default/History" "~/Library/Caches/BraveSoftware/Brave-Browser/Default/Cache"
    
    # macOS Safari (Native)
    SAFARI_HIST="$HOME/Library/Safari/History.db"
    if [ -f "$SAFARI_HIST" ]; then
        echo "[+] Found Safari history"
        send_status "Extracting Safari History..." 60
        mkdir -p "$TEMP_DIR/browsers/Safari"
        cp "$SAFARI_HIST" "$TEMP_DIR/browsers/Safari/History.db"
    fi
else
    # Linux Chromium-based browsers
    copy_chromium_data "Chrome" "~/.config/google-chrome/Default/History" "~/.cache/google-chrome/Default/Cache"
    copy_chromium_data "Brave" "~/.config/BraveSoftware/Brave-Browser/Default/History" "~/.cache/BraveSoftware/Brave-Browser/Default/Cache"
    copy_chromium_data "Edge" "~/.config/microsoft-edge/Default/History" "~/.cache/microsoft-edge/Default/Cache"
fi

# Firefox Profile Extraction (Linux & macOS)
send_status "Extracting Firefox Profiles..." 75
FF_DIR=""
FF_CACHE_DIR=""
if [ "$OS_TYPE" = "macOS" ]; then
    FF_DIR="$HOME/Library/Application Support/Firefox/Profiles"
    FF_CACHE_DIR="$HOME/Library/Caches/Firefox/Profiles"
else
    FF_DIR="$HOME/.mozilla/firefox"
    FF_CACHE_DIR="$HOME/.cache/mozilla/firefox"
fi

if [ -d "$FF_DIR" ]; then
    echo "[+] Found Firefox directory"
    mkdir -p "$TEMP_DIR/browsers/Firefox"
    
    # Find places.sqlite and cookies.sqlite in all profile folders
    find "$FF_DIR" -type f \( -name "places.sqlite" -o -name "cookies.sqlite" \) 2>/dev/null | while read -r file; do
        profile_name=$(basename "$(dirname "$file")")
        mkdir -p "$TEMP_DIR/browsers/Firefox/$profile_name"
        cp "$file" "$TEMP_DIR/browsers/Firefox/$profile_name/$(basename "$file")"
    done
    
    # Copy Firefox Cache
    if [ -d "$FF_CACHE_DIR" ]; then
        find "$FF_CACHE_DIR" -type d -name "cache2" 2>/dev/null | while read -r c_dir; do
            profile_name=$(basename "$(dirname "$c_dir")")
            mkdir -p "$TEMP_DIR/browsers/Firefox/$profile_name/Cache"
            find "$c_dir" -type f -size -5M -exec cp {} "$TEMP_DIR/browsers/Firefox/$profile_name/Cache/" \; 2>/dev/null
        done
    fi
fi

# 3. Compression
send_status "Compressing Forensic Package..." 85
echo "[*] Compressing gathered evidence..."

# Create ZIP archive
if command -v python3 >/dev/null 2>&1; then
    python3 -c "import shutil; shutil.make_archive('${ZIP_PATH%.zip}', 'zip', '$TEMP_DIR')"
elif command -v zip >/dev/null 2>&1; then
    (cd "$TEMP_DIR" && zip -q -r "$ZIP_PATH" .)
else
    send_error "No zip utilities found on target system."
    echo "[!] Error: Neither Python3 nor zip utility is installed on the target system."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# 4. Upload
send_status "Uploading evidence to S.E.I.Z.E. Pi..." 90
echo "[*] Uploading ZIP file ($(du -h "$ZIP_PATH" | cut -f1)) to ${BASE_URL}/upload..."

UPLOAD_RESP=$(curl -s -F "file=@${ZIP_PATH}" "${BASE_URL}/upload")

if echo "$UPLOAD_RESP" | grep -q "success"; then
    echo "[+] Ingestion complete! Data received."
else
    send_error "Upload failed: $UPLOAD_RESP"
    echo "[!] Error: Upload to Pi failed: $UPLOAD_RESP"
fi

# 5. Forensic Cleanup
echo "[*] Cleaning up temporary workspace..."
rm -rf "$TEMP_DIR"
rm -f "$ZIP_PATH"
echo "[*] Cleanup finished. Execution complete."
