#!/bin/bash
# S.E.I.Z.E. USB OTG Gadget Configuration Script
# Sets up the Raspberry Pi Zero 2 W as a composite network (RNDIS) and keyboard (HID) gadget.

set -e

# Load the composite driver module
modprobe libcomposite

# Create USB Gadget ConfigFS directory
GADGET_DIR="/sys/kernel/config/usb_gadget/seize"
if [ -d "$GADGET_DIR" ]; then
    echo "S.E.I.Z.E. USB Gadget already created."
    exit 0
fi

mkdir -p "$GADGET_DIR"
cd "$GADGET_DIR"

# 1. Define hardware identifiers
echo "0x1d6b" > idVendor   # Linux Foundation
echo "0x0104" > idProduct  # Multifunction Composite Gadget
echo "0x0100" > bcdDevice  # v1.0.0
echo "0x0200" > bcdUSB     # USB 2.0 (High speed)

# 2. String Descriptors (English 0x409)
mkdir -p strings/0x409
echo "SEIZE2026" > strings/0x409/serialnumber
echo "Nepal Police" > strings/0x409/manufacturer
echo "S.E.I.Z.E. Device" > strings/0x409/product

# 3. Create Configuration 1
mkdir -p configs/c.1
mkdir -p configs/c.1/strings/0x409
echo "Forensic Ingestion Config" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower

# 4. Function: USB Ethernet (RNDIS for Windows target support)
mkdir -p functions/rndis.usb0
# Set host & dev MAC addresses (avoiding collisions)
echo "42:ac:18:00:00:01" > functions/rndis.usb0/host_addr
echo "42:ac:18:00:00:02" > functions/rndis.usb0/dev_addr

# Windows RNDIS driver class/subclass override (extremely important for automatic Windows setup)
echo 1 > os_desc/use
echo 0xcd > os_desc/b_vendor_code
echo "MSFT100" > os_desc/qw_sign

mkdir -p configs/c.1/functions/rndis.usb0
ln -sf functions/rndis.usb0 configs/c.1/
mkdir -p os_desc/c.1
ln -sf configs/c.1 os_desc/c.1/

# 5. Function: USB Keyboard (HID) (Optional for BadUSB payload injection)
mkdir -p functions/hid.usb0
echo 1 > functions/hid.usb0/protocol
echo 1 > functions/hid.usb0/subclass
echo 8 > functions/hid.usb0/report_length
# Write standard keyboard report descriptor
echo -ne \\x05\\x01\\x09\\x06\\xa1\\x01\\x05\\x07\\x19\\xe0\\x29\\xe7\\x15\\x00\\x25\\x01\\x75\\x01\\x95\\x08\\x81\\x02\\x95\\x01\\x75\\x08\\x81\\x03\\x95\\x05\\x75\\x01\\x05\\x08\\x19\\x01\\x29\\x05\\x91\\x02\\x95\\x01\\x75\\x03\\x91\\x03\\x95\\x06\\x75\\x08\\x15\\x00\\x25\\x65\\x05\\x07\\x19\\x00\\x29\\x65\\x81\\x00\\xc0 > functions/hid.usb0/report_desc
ln -sf functions/hid.usb0 configs/c.1/

# 6. Bind to hardware UDC controller
UDC_NAME=$(ls /sys/class/udc | head -n 1)
if [ -n "$UDC_NAME" ]; then
    echo "$UDC_NAME" > UDC
    echo "USB OTG Gadget initialized and bound to controller: $UDC_NAME"
else
    echo "Error: No hardware USB UDC controller found. Is OTG driver dwc2 enabled?" >&2
    exit 1
fi
