# S.E.I.Z.E.

S.E.I.Z.E. stands for Swift Electronic Ingestion & Zero-delay Extraction. This repository contains the Raspberry Pi gateway, OLED dashboard, payload scripts, and central server receiver used to collect and forward forensic capture packages.

## What’s In The Repo

- `config/` contains the Pi boot, network, and service configuration.
- `dashboard/` contains the OLED status display daemon.
- `payloads/` contains the Windows and Linux/macOS collection scripts.
- `server/` contains the Pi-side gateway and the central receiver service.
- `setup_instructions.md` contains the long-form deployment guide.

## Requirements

- Raspberry Pi Zero 2 W or similar Pi with USB OTG support.
- Raspberry Pi OS Lite 64-bit.
- SSD1306 OLED display on I2C.
- Python 3 with Flask, Requests, Pillow, and luma.oled on the Pi.
- A central server or workstation reachable from the Pi.

## Quick Setup

1. Enable USB OTG gadget mode and I2C on the Pi.
2. Copy `config/`, `dashboard/`, and `server/` into `/opt/seize/` on the Pi.
3. Install the required system packages and Python libraries.
4. Configure the central server IP in `/opt/seize/config/server_ip.txt`.
5. Install the systemd services from `config/` and enable them.

See [setup_instructions.md](setup_instructions.md) for the full step-by-step deployment guide.

## Running The Services

On the Pi, the main services are:

- `seize_server.service` for the Flask gateway in `server/proxy_gate.py`.
- `seize_oled.service` for the display daemon in `dashboard/oled_dashboard.py`.

The gadget startup script is `config/setup_gadget.sh`.

## Payload Usage

The payload scripts in `payloads/` are intended to be served by the Pi gateway and executed on a target machine you are authorized to examine.

- `payloads/seize.ps1` for Windows targets.
- `payloads/seize.sh` for Linux and macOS targets.

## Central Receiver

The central receiver in `server/receiver.py` accepts uploaded evidence packages, extracts them into the local storage directory, and updates shared status information for the OLED dashboard.

## Notes

Use this project only on systems you are authorized to inspect.
