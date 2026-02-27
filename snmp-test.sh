#!/bin/bash

# --- Helper Functions ---

show_mem_disk() {
  local mem=$(free --mega | awk '/^Mem:/{printf "%.0fG", $2/1000}')
  local disk=$(lsblk -bdno SIZE /dev/mmcblk0 | awk '{printf "%.0fG", $1/1000/1000/1000}')

  if [ "$1" == "raw" ]; then
    echo -e "Memory: $mem\nDisk: $disk"
  else
    echo -e "Memory :${GREEN}${mem}${NC}"
    echo -e "Disk   :${GREEN}${disk}${NC}"
  fi
}

show_wifi_mac() {
  for interface in /sys/class/net/*; do
    if [ -d "$interface/wireless" ] || [ -d "$interface/phy80211" ]; then
      local mac=$(cat "$interface/address")
      if [ "$1" == "raw" ]; then
        echo "MAC: $mac"
      else
        echo -e "MAC    : ${GREEN}${mac}${NC}"
      fi
      return 0
    fi
  done
  return 1
}

send_smtp_email() {
  # 1. Configuration
  local SMTP_SERVER="tiger"
  local SMTP_PORT=25
  local SENDER_EMAIL="sf@feakes.cc"
  local RECIPIENT_EMAIL="sf@feakes.cc"
  local subject="System Report: $(hostname)"

  # 2. Collect Data
  local RAW_STATS=$(show_mem_disk raw)
  local RAW_MAC=$(show_wifi_mac raw)
  local RAW_MODEL=$(tr -d '\0' < /sys/firmware/devicetree/base/model 2>/dev/null || echo "Unknown Model")

  # 3. Build the actual body string
  local MESSAGE=$(cat <<EOF
System Report for $(hostname)
Date: $(date)
--------------------------------------
Model:  $RAW_MODEL
$RAW_STATS
$RAW_MAC
--------------------------------------
EOF
)

  # 4. Open Connection
  if ! exec 3<>/dev/tcp/"$SMTP_SERVER"/"$SMTP_PORT"; then
    echo "Error: Could not connect to $SMTP_SERVER on port $SMTP_PORT"
    return 1
  fi

  # 5. SMTP Helper
  send() {
    echo -ne "$1\r\n" >&3
    sleep 0.5
  }

  # 6. SMTP Handshake
  send "HELO $(hostname)"
  send "MAIL FROM: <$SENDER_EMAIL>"
  send "RCPT TO: <$RECIPIENT_EMAIL>"
  send "DATA"
  
  # 7. Headers
  echo -ne "From: $SENDER_EMAIL\r\n" >&3
  echo -ne "To: $RECIPIENT_EMAIL\r\n" >&3
  echo -ne "Subject: $subject\r\n" >&3
  echo -ne "Content-Type: text/plain; charset=UTF-8\r\n" >&3
  echo -ne "\r\n" >&3 

  # 8. Send Body Content
  echo -ne "$MESSAGE\r\n" >&3
  
  send "."
  send "QUIT"
  exec 3>&-
  echo "Email sent successfully to $RECIPIENT_EMAIL"
}

# --- Execution ---
send_smtp_email