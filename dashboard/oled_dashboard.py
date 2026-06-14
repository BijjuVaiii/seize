import os
import sys
import time
import json
import shutil
import socket

# Try to import Luma and Pillow. If not installed, run in Mock Mode.
try:
    from luma.core.interface.serial import i2c
    from luma.core.render import canvas
    from luma.oled.device import ssd1306
    from PIL import Image, ImageDraw, ImageFont
    HAS_OLED = True
except ImportError:
    HAS_OLED = False
    print("Warning: luma.oled or PIL libraries not found. Running in MOCK/CONSOLE mode.")

STATUS_FILE = "/dev/shm/seize_status.json"

# Fallback fonts
# On Raspberry Pi OS, standard fonts are in /usr/share/fonts/truetype/
FONT_PATHS = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
]

def get_font(size, bold=False):
    if not HAS_OLED:
        return None
    for path in FONT_PATHS:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                pass
    # Fallback to default
    return ImageFont.load_default()

def get_sys_temp():
    try:
        with open("/sys/class/thermal/thermal_zone0/temp", "r") as f:
            temp_raw = int(f.read().strip())
            return f"{temp_raw / 1000.0:.1f}°C"
    except Exception:
        return "N/A"

def get_sys_storage():
    try:
        usage = shutil.disk_usage("/data" if os.path.exists("/data") else "/")
        free_gb = usage.free / (1024**3)
        total_gb = usage.total / (1024**3)
        return f"{free_gb:.1f}G/{total_gb:.0f}G"
    except Exception:
        return "N/A"

def get_sys_ram():
    try:
        with open("/proc/meminfo", "r") as f:
            lines = f.readlines()
        mem_total = 0
        mem_free = 0
        mem_available = 0
        for line in lines:
            if "MemTotal" in line:
                mem_total = int(line.split()[1])
            elif "MemAvailable" in line:
                mem_available = int(line.split()[1])
        if mem_total > 0:
            used = mem_total - mem_available
            percent = (used / mem_total) * 100
            return f"{percent:.0f}%"
    except Exception:
        pass
    return "N/A"

def format_size(bytes_sz):
    if bytes_sz is None or bytes_sz == 0:
        return "0 B"
    for unit in ['B', 'KB', 'MB', 'GB']:
        if bytes_sz < 1024.0:
            return f"{bytes_sz:.1f} {unit}"
        bytes_sz /= 1024.0
    return f"{bytes_sz:.1f} TB"

def read_status():
    if os.path.exists(STATUS_FILE):
        try:
            with open(STATUS_FILE, 'r') as f:
                return json.load(f)
        except Exception:
            pass
    return {
        "state": "IDLE",
        "hostname": "N/A",
        "os": "N/A",
        "current_task": "System initialized.",
        "percent": 0,
        "bytes_received": 0,
        "elapsed_time": "0s",
        "saved_path": "",
        "error_message": ""
    }

def draw_dashboard(draw, width, height, status, blink_state):
    # Colors (OLED is monochrome, so 255 is White, 0 is Black)
    WHITE = 255
    BLACK = 0

    # Draw Header (Common for all screens)
    draw.text((0, 0), "S.E.I.Z.E. v1.0", font=get_font(11, bold=True), fill=WHITE)
    
    # Blinking police indicator (NP) on the top right
    np_indicator = "NP [OK]" if blink_state else "NP  OK "
    draw.text((85, 0), np_indicator, font=get_font(9), fill=WHITE)
    draw.line((0, 13, width, 13), fill=WHITE)

    state = status.get("state", "IDLE")

    if state == "IDLE":
        # Draw Idle Screen (System Stats & Network Info)
        draw.text((0, 16), "NEPAL POLICE FORENSICS", font=get_font(9, bold=True), fill=WHITE)
        draw.text((0, 28), "STATUS: READY TO PLUG", font=get_font(9), fill=WHITE)
        draw.text((0, 39), "IP: 192.168.7.1", font=get_font(9), fill=WHITE)
        
        # System status bar at the bottom
        temp = get_sys_temp()
        storage = get_sys_storage()
        draw.line((0, 52, width, 52), fill=WHITE)
        draw.text((0, 54), f"T:{temp}  RAM:{get_sys_ram()}  SD:{storage}", font=get_font(8), fill=WHITE)

    elif state == "CONNECTED" or state == "EXTRACTING":
        # Extraction Screen
        hostname = status.get("hostname", "UNKNOWN")
        percent = status.get("percent", 0)
        current_task = status.get("current_task", "Extracting...")
        elapsed = status.get("elapsed_time", "0s")
        
        # Limit hostname to fit screen
        if len(hostname) > 15:
            hostname = hostname[:13] + ".."
            
        draw.text((0, 15), f"Target: {hostname}", font=get_font(9, bold=True), fill=WHITE)
        
        # Display current subtask (wrap or truncate to fit 20 chars)
        if len(current_task) > 22:
            # Let's show the end of it or truncate
            display_task = ".." + current_task[-20:]
        else:
            display_task = current_task
        draw.text((0, 26), display_task, font=get_font(8), fill=WHITE)

        # Progress bar
        bar_y = 38
        bar_height = 8
        bar_width = 100
        # Draw outline
        draw.rectangle((0, bar_y, bar_width, bar_y + bar_height), outline=WHITE, fill=BLACK)
        # Draw filled part
        if percent > 0:
            fill_width = int((percent / 100.0) * bar_width)
            # Ensure it doesn't overflow
            fill_width = min(max(fill_width, 1), bar_width)
            draw.rectangle((0, bar_y, fill_width, bar_y + bar_height), outline=WHITE, fill=WHITE)
            
        # Percent text
        draw.text((104, 37), f"{percent}%", font=get_font(9), fill=WHITE)
        
        # Time elapsed & status description
        draw.text((0, 49), f"Time: {elapsed}", font=get_font(8), fill=WHITE)
        bytes_rec = format_size(status.get("bytes_received", 0))
        draw.text((70, 49), bytes_rec, font=get_font(8), fill=WHITE)

    elif state == "SAVING":
        # Saving State (writing to disk/unzipping)
        draw.text((0, 18), "SAVING DATA...", font=get_font(12, bold=True), fill=WHITE)
        draw.text((0, 32), "Unzipping & cataloging", font=get_font(9), fill=WHITE)
        draw.text((0, 44), "Please do not unplug!", font=get_font(9), fill=WHITE)
        
        # Small progress bar at bottom
        draw.rectangle((0, 56, width, 60), outline=WHITE, fill=BLACK)
        draw.rectangle((0, 56, int(width * 0.9), 60), outline=WHITE, fill=WHITE)

    elif state == "COMPLETED":
        # Successful Extraction Screen
        hostname = status.get("hostname", "UNKNOWN")
        elapsed = status.get("elapsed_time", "0s")
        size_str = format_size(status.get("bytes_received", 0))
        sync = status.get("server_sync", "OFFLINE")
        
        draw.text((0, 15), "EXTRACTION COMPLETE", font=get_font(10, bold=True), fill=WHITE)
        draw.text((0, 27), f"Device: {hostname}", font=get_font(9), fill=WHITE)
        draw.text((0, 37), f"Data Size: {size_str} ({elapsed})", font=get_font(8), fill=WHITE)
        
        # Display sync state feedback
        if sync == "SYNCED":
            draw.text((0, 47), "SYNCED TO CENTRAL SERVER", font=get_font(8, bold=True), fill=WHITE)
        else:
            draw.text((0, 47), "CACHED LOCALLY (OFFLINE)", font=get_font(8, bold=True), fill=WHITE)
            
        # Action hint
        draw.text((0, 57), "Safe to unplug device.", font=get_font(8), fill=WHITE)

    elif state == "FAILED":
        # Error Screen
        error_msg = status.get("error_message", "Unknown error")
        if len(error_msg) > 40:
            error_msg = error_msg[:37] + "..."
            
        draw.text((0, 15), "CAPTURE FAILED!", font=get_font(11, bold=True), fill=WHITE)
        # Split error message into two lines if needed
        draw.text((0, 28), error_msg[:22], font=get_font(8), fill=WHITE)
        if len(error_msg) > 22:
            draw.text((0, 38), error_msg[22:44], font=get_font(8), fill=WHITE)
            
        draw.text((0, 52), "Reconnect & try again.", font=get_font(9), fill=WHITE)

def main():
    print("S.E.I.Z.E. OLED Daemon Started.")
    
    device = None
    if HAS_OLED:
        try:
            # SSD1306 connection via I2C (port 1 is standard for Pi 3/4/Zero)
            serial = i2c(port=1, address=0x3C)
            device = ssd1306(serial)
            print("SSD1306 OLED initialized successfully on I2C address 0x3C.")
        except Exception as e:
            print(f"Error initializing SSD1306 OLED display: {e}")
            print("Running daemon in Console output mode.")
            
    blink_state = False
    last_state = None
    last_percent = -1
    
    while True:
        status = read_status()
        state = status.get("state", "IDLE")
        percent = status.get("percent", 0)
        
        # Only print to console if state or progress changed (avoid spamming)
        if state != last_state or percent != last_percent:
            print(f"State: {state} | Progress: {percent}% | Task: {status.get('current_task')}")
            last_state = state
            last_percent = percent
            
        if HAS_OLED and device:
            try:
                with canvas(device) as draw:
                    draw_dashboard(draw, device.width, device.height, status, blink_state)
            except Exception as e:
                print(f"OLED drawing error: {e}")
                
        blink_state = not blink_state
        time.sleep(0.5)  # Update display twice a second

if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print("\nExiting OLED Daemon.")
        sys.exit(0)
