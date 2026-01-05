#!/bin/bash

#
# curl -fsSL http://tiger/scratch/raspberry/cleanup | sudo bash -s --
# curl -fsSL http://tiger/scratch/radxa/images/cleanup | sudo bash -s --


RADXA_BOOT_CFG="/boot/extlinux/extlinux.conf"
PI_BOOT_CFG="/boot/firmware/config.txt"

RADXA_PATCH_URL="https://raw.githubusercontent.com/aqualinkd/AqualinkD-Radxa-zero3/refs/heads/main/patch-update"
PI_PATCH_URL="https://raw.githubusercontent.com/aqualinkd/AqualinkD-Raspberry-CM/refs/heads/main/patch-update"

TRUE=0
FALSE=1

_pi=$FALSE
_radxa=$FALSE


# Define colors
GREEN='\e[32m'
RED='\e[31m'
NC='\e[0m' # No Color (Reset)


# check root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

if grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
  echo "This is a Raspberry Pi."
  _pi=$TRUE
elif grep -q "Radxa ZERO" /proc/device-tree/model 2>/dev/null; then
  echo "This is a RADXA"
  _radxa=$TRUE
else
  echo "Unknown SBC"
  exit 1
fi

set_us_timezone() {
  echo "Select a US Time Zone:"
  echo "1) Eastern"
  echo "2) Central"
  echo "3) Mountain"
  echo "4) Pacific"
  echo "5) Alaska"
  echo "6) Hawaii"
  
  read -rp "Enter choice [1-6]: " tz_choice

  case $tz_choice in
    1) zone="US/Eastern" ;;
    2) zone="US/Central" ;;
    3) zone="US/Mountain" ;;
    4) zone="US/Pacific" ;;
    5) zone="US/Alaska" ;;
    6) zone="US/Hawaii" ;;
    *) 
      echo "Invalid selection. Timezone not changed."
      return 1 
      ;;
  esac

  msg "Setting timezone to $zone..."
  if sudo timedatectl set-timezone "$zone"; then
    echo "Timezone successfully set to $(timedatectl show --property=Timezone --value)."
  else
    echo "Error: Failed to set timezone."
  fi
}

check_raspiconfig_options() {
  if grep -q "^[[:space:]]*dtparam=ant2" $PI_BOOT_CFG; then
    echo -e "External Antenna is ${GREEN}ENABLED!${NC}"
  else
    echo -e "External Antenna is ${RED}DISABLED!${NC}"
  fi

  echo -e "Timezone is ${GREEN}`cat /etc/timezone`${NC}"

  # Force tty since this is pipe from curl
  read -p 'Did you set Antenna & time correctly? (y/n) ' -n 1 -r < /dev/tty
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    raspi-config
    check_raspiconfig_options
  else
    echo ""
  fi
}

check_rsetup_options() {
  if grep -q "external-antenna.dtbo" $RADXA_BOOT_CFG; then
    echo "External Antenna is ENABLED!"
  else
    echo "External Antenna is DISABLED!"
  fi

  echo "Timezone is `cat /etc/timezone`"

  # Force tty since this is pipe from curl
  read -p 'Did you set Antenna & time correctly? (y/n) ' -n 1 -r < /dev/tty
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    rsetup
    check_rsetup_options
  else
    echo ""
  fi
}

check_wifi_visibility() {
    echo "Scanning for Wi-Fi networks..."
    
    # 1. Trigger rescan
    sudo nmcli device wifi rescan 2>/dev/null
    sleep 2

    # 2. Use --colors yes to force color output even through the pipe
    # Use tee /dev/tty to show the colored output to the user immediately
    local wifi_list
    wifi_list=$(sudo nmcli --colors yes -f SSID,BARS,SIGNAL device wifi list | tee /dev/tty)

    # 3. Process the list for the count
    # Note: grep handles the color codes fine when looking for the header
    local count
    count=$(echo "$wifi_list" | grep -v "SSID" | grep -v '^--' | grep -v '^$' | wc -l)

    echo "------------------------------------------"
    if [[ "$count" -gt 0 ]]; then
        echo -e "${GREEN}[OK]${NC} Wi-Fi found $count network(s)."
        return 0
    else
        echo -e "${RED}[ERROR${NC} No Wi-Fi networks found in range!"
        return 1
    fi
}

########################################################################
#
#.  main
#

CALLED_URL=""

# Loop through all arguments passed after the "--"
for arg in "$@"; do
  case $arg in
    url=*)
      # Strip "url=" from the start of the string
      CALLED_URL="${arg#url=}"
      shift # Remove from processing
      ;;
  esac
done

# Check if it was found
if [[ -n "$CALLED_URL" ]]; then
    echo "This script was downloaded from: $CALLED_URL"
    RADXA_PATCH_URL="$CALLED_URL/aqualinkd-kit-tools/radxa-patch-update"
    PI_PATCH_URL="$CALLED_URL/aqualinkd-kit-tools/raspberry-patch-update"
else
    echo "No URL parameter provided."
fi

if [[ "$_pi" -eq "$TRUE" ]]; then
    check_raspiconfig_options
elif [[ "$_radxa" -eq "$TRUE" ]]; then
    check_rsetup_options
#else
    # Generic Linux logic
fi



read -p 'Do you want to run patch update? (y/n) ' -n 1 -r < /dev/tty
if [[ $REPLY =~ ^[Yy]$ ]]; then
  if [[ "$_pi" -eq "$TRUE" ]]; then
    curl -fsSL $PI_PATCH_URL | sudo bash -s --
  elif [[ "$_radxa" -eq "$TRUE" ]]; then
    curl -fsSL $RADXA_PATCH_URL | sudo bash -s --
  fi
else
  echo ""
fi

if ! check_wifi_visibility; then
    echo "${RED}[ERROR]${EM} No networks found. Check hardware."
    exit 1
fi

# If we reached here, it means it passed!

sudo journalctl --flush --rotate --vacuum-time=1s
sudo journalctl --user --flush --rotate --vacuum-time=1s
sudo rm -rf /var/log/journal/*
sudo rm /home/radxa/.bash_history 2> /dev/null
sudo rm /root/.bash_history 2> /dev/null


read -rep 'Halt / Reboot system, or exit? (H/R/E)' -n 1 -r < /dev/tty
if [[ $REPLY =~ ^[Hh]$ ]]; then
  echo "Halting system!"
  sudo halt
elif [[ $REPLY =~ ^[Rr]$ ]]; then
  echo "Rebooting system!"
  sudo reboot
else
  echo ""
fi


