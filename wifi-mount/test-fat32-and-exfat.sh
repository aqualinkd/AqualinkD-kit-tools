#!/bin/bash
#
# Test script for auto-wifi-connect with both FAT32 and exFAT USB images
# Tests: device detection, mounting, config discovery, WiFi setup
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_WIFI="$SCRIPT_DIR/auto-wifi-connect"
TEST_DIR="/tmp/auto-wifi-test"
MOUNT_BASE="$TEST_DIR/mounts"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counters
PASSED=0
FAILED=0

log_test() {
  echo -e "${YELLOW}[TEST]${NC} $*"
}

log_pass() {
  echo -e "${GREEN}[PASS]${NC} $*"
  ((PASSED++))
}

log_fail() {
  echo -e "${RED}[FAIL]${NC} $*"
  ((FAILED++))
}

cleanup() {
  echo "Cleaning up test environment..."
  # Unmount all test mounts
  for mount in "$MOUNT_BASE"/*; do
    if [ -d "$mount" ] && mountpoint -q "$mount" 2>/dev/null; then
      umount "$mount" || true
    fi
  done
  # Detach loopback devices
  for loop in /dev/loop{0..9}; do
    losetup -d "$loop" 2>/dev/null || true
  done
  # Remove test directory
  rm -rf "$TEST_DIR"
}

trap cleanup EXIT

# Verify we have required tools
check_requirements() {
  local required=("mkfs.vfat" "file" "losetup" "mount" "umount" "mkfs.exfat")
  for cmd in "${required[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      # For mkfs.exfat, check if exfat-utils is available
      if [ "$cmd" = "mkfs.exfat" ] && ! command -v mkfs.exfat &>/dev/null; then
        log_fail "Missing: $cmd (install exfat-utils or exfatprogs)"
        return 1
      fi
    fi
  done
  return 0
}

# Create FAT32 loopback image
create_fat32_image() {
  local img="$TEST_DIR/usb-fat32.img"
  local size="${1:-10M}"
  
  log_test "Creating FAT32 image ($size)..."
  
  # Create empty image file
  dd if=/dev/zero of="$img" bs=1M count=10 2>/dev/null
  
  # Format as FAT32
  mkfs.vfat -F 32 "$img" > /dev/null 2>&1 || {
    log_fail "Failed to create FAT32 filesystem"
    return 1
  }
  
  echo "$img"
}

# Create exFAT loopback image
create_exfat_image() {
  local img="$TEST_DIR/usb-exfat.img"
  local size="${1:-10M}"
  
  log_test "Creating exFAT image ($size)..."
  
  # Create empty image file
  dd if=/dev/zero of="$img" bs=1M count=10 2>/dev/null
  
  # Format as exFAT
  mkfs.exfat "$img" > /dev/null 2>&1 || {
    log_fail "Failed to create exFAT filesystem"
    return 1
  }
  
  echo "$img"
}

# Mount image via loopback and verify filesystem type
test_filesystem_detection() {
  local img="$1"
  local fstype="$2"  # "FAT32" or "exFAT"
  
  log_test "Testing $fstype detection via 'file' command..."
  
  # Detect filesystem using file command (same as script does)
  local detected
  detected=$(file -s "$img" | grep -o 'FAT\|exFAT' || echo "UNKNOWN")
  
  if [[ "$detected" == "FAT" || "$detected" == "exFAT" ]]; then
    log_pass "$fstype correctly detected as: $detected"
    return 0
  else
    log_fail "$fstype detection failed (got: $detected)"
    return 1
  fi
}

# Test mounting and config file discovery
test_mount_and_config() {
  local img="$1"
  local fstype="$2"
  local mount_point="$MOUNT_BASE/$fstype"
  
  mkdir -p "$mount_point"
  
  log_test "Testing $fstype mount..."
  
  # Get free loop device
  local loop_dev
  loop_dev=$(losetup -f)
  
  # Attach loopback
  losetup "$loop_dev" "$img" || {
    log_fail "Failed to attach loopback for $fstype"
    return 1
  }
  
  # Mount with same options as script
  mount "$loop_dev" "$mount_point" -o rw,sync,iocharset=utf8 2>/dev/null || {
    log_fail "Failed to mount $fstype image"
    losetup -d "$loop_dev"
    return 1
  }
  
  log_pass "$fstype mounted at $mount_point"
  
  # Test config file creation and discovery
  log_test "Testing config file discovery on $fstype..."
  
  # Create test wpa_supplicant.conf
  cat > "$mount_point/wpa_supplicant.conf" << 'EOF'
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
  ssid="TestNetwork"
  psk="TestPassword123"
  key_mgmt=WPA-PSK
}
EOF
  
  # Test file readability
  if [ -f "$mount_point/wpa_supplicant.conf" ]; then
    log_pass "Config file created and readable on $fstype"
  else
    log_fail "Config file not readable on $fstype"
    umount "$mount_point"
    losetup -d "$loop_dev"
    return 1
  fi
  
  # Create nmcli.conf too
  cat > "$mount_point/nmcli.conf" << 'EOF'
SSID=TestNetwork2
PASSWORD=TestPassword456
EOF
  
  if [ -f "$mount_point/nmcli.conf" ]; then
    log_pass "nmcli.conf created and readable on $fstype"
  else
    log_fail "nmcli.conf not readable on $fstype"
  fi
  
  # Verify file permissions (some filesystems handle this differently)
  ls -la "$mount_point"/ | grep -q "wpa_supplicant.conf" && {
    log_pass "$fstype preserves file listings"
  }
  
  # Cleanup
  umount "$mount_point" || {
    log_fail "Failed to unmount $fstype"
  }
  
  losetup -d "$loop_dev"
  log_pass "$fstype unmounted successfully"
  
  return 0
}

# Test script function: get_value_string (if sourced)
test_config_parsing() {
  local img="$1"
  local fstype="$2"
  local mount_point="$MOUNT_BASE/$fstype-parse"
  
  mkdir -p "$mount_point"
  
  log_test "Testing config parsing on $fstype..."
  
  # Get free loop device
  local loop_dev
  loop_dev=$(losetup -f)
  losetup "$loop_dev" "$img" || return 1
  mount "$loop_dev" "$mount_point" -o rw,sync,iocharset=utf8 2>/dev/null || {
    losetup -d "$loop_dev"
    return 1
  }
  
  # Create test config
  cat > "$mount_point/nmcli.conf" << 'EOF'
SSID=MyWiFiNetwork
PASSWORD=SecurePassword123
EOF
  
  # Source the auto-wifi-connect script functions (if safe)
  if grep -q "function get_value_string" "$AUTO_WIFI"; then
    # Extract and test the get_value_string function
    source <(sed -n '/^function get_value_string/,/^}/p' "$AUTO_WIFI")
    
    # Test parsing
    local ssid password
    ssid=$(get_value_string "$mount_point/nmcli.conf" "SSID")
    password=$(get_value_string "$mount_point/nmcli.conf" "PASSWORD")
    
    if [ "$ssid" = "MyWiFiNetwork" ]; then
      log_pass "$fstype: Correctly parsed SSID"
    else
      log_fail "$fstype: Failed to parse SSID (got: $ssid)"
    fi
    
    if [ "$password" = "SecurePassword123" ]; then
      log_pass "$fstype: Correctly parsed PASSWORD"
    else
      log_fail "$fstype: Failed to parse PASSWORD"
    fi
  fi
  
  umount "$mount_point" 2>/dev/null || true
  losetup -d "$loop_dev"
  
  return 0
}

# Main test execution
main() {
  echo "=========================================="
  echo "auto-wifi-connect Test Suite"
  echo "Testing: FAT32 & exFAT USB mounting"
  echo "=========================================="
  echo
  
  # Check requirements
  if ! check_requirements; then
    echo "Cannot run tests: missing required tools"
    exit 1
  fi
  
  # Setup
  mkdir -p "$MOUNT_BASE"
  
  # Test FAT32
  echo
  echo "--- FAT32 Tests ---"
  fat32_img=$(create_fat32_image) || exit 1
  test_filesystem_detection "$fat32_img" "FAT32" || true
  test_mount_and_config "$fat32_img" "FAT32" || true
  test_config_parsing "$fat32_img" "FAT32" || true
  
  # Test exFAT
  echo
  echo "--- exFAT Tests ---"
  exfat_img=$(create_exfat_image) || exit 1
  test_filesystem_detection "$exfat_img" "exFAT" || true
  test_mount_and_config "$exfat_img" "exFAT" || true
  test_config_parsing "$exfat_img" "exFAT" || true
  
  # Results
  echo
  echo "=========================================="
  echo -e "Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
  echo "=========================================="
  
  [ $FAILED -eq 0 ] && exit 0 || exit 1
}

main "$@"
