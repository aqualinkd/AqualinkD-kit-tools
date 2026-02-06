#!/bin/bash

# This script depends on usbboot, make sure it's compiled first.
# https://github.com/raspberrypi/usbboot


# --- CONFIGURATION ---
#IMAGE_NAME="/path/to/hardcoded/IMAGE_NAME.img"
IMAGE_NAME="raspios-aqualinkd-trixie-arm64-lite.img"

BINARY_NAME="rpiboot"  # The binary we are looking for

# OS-Specific Default Paths for the binary
OSX_BIN_PATH="/Users/sf/raspberry/usbboot/$BINARY_NAME"
LINUX_BIN_PATH="/nas/data/Development/Raspberry/AqualinkD-kit-tools/usb-tools/usbboot/$BINARY_NAME"


# Define colors
GREEN='\e[32m'
RED='\e[31m'
NC='\e[0m' # No Color (Reset)


# Function to detect the parent disk of the 'bootfs' volume
#find_rpi_disk() {
#    diskutil info "bootfs" 2>/dev/null | grep "Part of Whole" | awk '{print $4}'
#}

find_pi_mount_disk() {
    local os_type
    os_type=$(uname -s)

    if [[ "$os_type" == "Darwin" ]]; then
        # macOS/OSX Logic
        # Returns /dev/diskN
        #diskutil info "bootfs" 2>/dev/null | grep "Part of Whole" | awk '{print $4}'
        diskutil info -all | grep -B 10 "mmcblk0 Media" | grep "Device Node" | awk '{print $3}'
    elif [[ "$os_type" == "Linux" ]]; then
        # Linux Logic (Debian/Ubuntu/Radxa)
        # 1. Find the partition device by label (e.g., /dev/sdb1)
        # 2. Get the parent disk (PKNAME) (e.g., /dev/sdb)
        local part_dev
        part_dev=$(lsblk -no NAME,LABEL | grep -i "bootfs" | awk '{print $1}')
        
        if [[ -n "$part_dev" ]]; then
            # Full path to the parent block device (e.g. /dev/sda)
            echo "/dev/$(lsblk -no PKNAME "/dev/$part_dev" | head -n 1)"
        fi
    else
        echo "Unsupported OS: $os_type" >&2
        return 1
    fi
}





###################################
#
# main
#

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with sudo."
  exit 1
fi

# --- ARGUMENT PARSING ---
IMAGE_FILE="$IMAGE_NAME"
SELECTED_BIN=""

while getopts "i:b:" opt; do
  case $opt in
    i) IMAGE_FILE="$OPTARG" ;;
    b) SELECTED_BIN="$OPTARG" ;;
    *) echo "Usage: $0 [-i image_file] [-b binary]"; exit 1 ;;
  esac
done

# --- BINARY RESOLUTION LOGIC ---
if [[ -z "$SELECTED_BIN" ]]; then
    # 1. Check if it's already in the user's PATH
    if command -v "$BINARY_NAME" >/dev/null 2>&1; then
        SELECTED_BIN=$(command -v "$BINARY_NAME")
    else
        # 2. Check OS and set default path
        OS_TYPE=$(uname -s)
        if [[ "$OS_TYPE" == "Darwin" ]]; then
            SELECTED_BIN="$OSX_BIN_PATH"
        else
            # Default to Linux path for Linux or other Unix-like systems
            SELECTED_BIN="$LINUX_BIN_PATH"
        fi
    fi
fi


# Get the directory of the current script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve IMAGE_PATH based on your priority:
if [[ ! -f "$IMAGE_FILE" ]]; then   
  if [[ -f "./$IMAGE_FILE" ]]; then
    #  Look in the Current Working Directory
    IMAGE_FILE="./$IMAGE_FILE"
  elif [[ -f "$SCRIPT_DIR/$IMAGE_FILE" ]]; then
    # Look in the Directory where the script is located
    IMAGE_FILE="$SCRIPT_DIR/$IMAGE_FILE"
  else
    echo "Error: Image file not found at $IMAGE_FILE"
    exit
  fi
fi


if [[ ! -x "$SELECTED_BIN" ]]; then
    echo "Error: Binary not found or not executable at $SELECTED_BIN"
    exit
fi


# --- VALIDATION ---
echo "--- Configuration ---"
echo -e "Image File: $GREEN $IMAGE_FILE ${NC}"
echo "Binary:     $SELECTED_BIN"


# PRE-CHECK: Is the Pi already mounted as a disk?
echo "Checking if Raspberry Pi is already initialized..."
#RPI_DISK=$(find_rpi_disk)
RPI_DISK=$(find_pi_mount_disk)

RPIBOOT_PATH=$(dirname "$SELECTED_BIN")

if [ -z "$RPI_DISK" ]; then
  echo "Pi not found. Running rpiboot..."
  # Run rpiboot to initialize the Compute Module
  echo "Initializing Raspberry Pi eMMC via rpiboot..."
  $SELECTED_BIN -d $RPIBOOT_PATH/mass-storage-gadget64

  # Wait for macOS to mount 'bootfs' and detect the disk
  echo "Waiting for 'mmcblk0 Media' to mount..."
  max_retries=15
  count=0
  RPI_DISK=""

  while [ $count -lt $max_retries ]; do
    #RPI_DISK=$(find_rpi_disk)
    RPI_DISK=$(find_pi_mount_disk)
    if [ -n "$RPI_DISK" ]; then break; fi
    sleep 2
    ((count++))
  done
else
    echo "Pi already detected at $RPI_DISK. Skipping rpiboot."
fi

# Handle detection failure
if [ -z "$RPI_DISK" ]; then
  echo "FAILURE: Could not detect 'bootfs' after rpiboot."
  exit 1
fi

printf "SUCCESS: Detected Raspberry Pi at ${GREEN}$RPI_DISK${NC}\n"
 

if [[ "$(uname -s)" == "Darwin" ]]; then
    # macOS/OSX Command
    diskutil list "$RPI_DISK"
    # Use 'rdisk' for faster write speeds on macOS
    RAW_DISK="${RPI_DISK/disk/rdisk}"
    DD_OPTS=""
else
    # Linux Command (Debian/Ubuntu/Radxa)
    # Lists partitions with their size, type, and mountpoint
    sudo lsblk -p -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$RPI_DISK"
    RAW_DISK=${RPI_DISK}
    DD_OPTS="oflag=direct"
fi

# Check to continue
echo -n "Ready to flash image to $RPI_DISK? (y/n): "
read -n 1 user_reply
echo "" # Move to a new line after the keypress

if [[ "$user_reply" =~ ^[Yy]$ ]]; then
  # Unmount disk to prevent 'Resource Busy' errors
  echo "Unmounting $RPI_DISK..."
  diskutil unmountDisk "$RPI_DISK"

  # Use 'rdisk' for faster write speeds on macOS
  RAW_DISK="${RPI_DISK/disk/rdisk}"
  echo "Executing flash to $RAW_DISK... (this may take a few minutes)"
    
  dd bs=4M if="$IMAGE_FILE" of="$RAW_DISK" status=progress $DD_OPTS
    
  sync
  echo "Flash completed successfully. You can now disconnect the Pi."
else
  echo "Operation cancelled."
fi

