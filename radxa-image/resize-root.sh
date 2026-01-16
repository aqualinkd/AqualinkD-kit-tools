#!/bin/bash


# curl -fsSL http://tiger/scratch/radxa/images/resize-root.sh | sudo bash -s --

# Define the device (usually /dev/mmcblk0 for SD cards)
DEVICE="/dev/mmcblk0"
PARTNUM="3"

# Identify the root partition (typically the third partition)
ROOT_PARTITION="${DEVICE}p${PARTNUM}" 

#echo "Current size"
df -h | grep /dev/mmcblk0p3 | awk '{ printf "Current size \033[32m%s\033[0m\n", $2 }'

# Use parted to resize the partition.
# The 'resizepart 3 100%' command resizes the partition to 100% of the available space.
# Ensure the partition number matches your root partition.

echo "Resizing partition ${ROOT_PARTITION} to fill the available space..."


# 1. Clean up GPT headers first (The "Silent Fixer")
# This uses fdisk's internal logic to relocate the backup header.
# It works silently if no fix is needed, and fixes it if it is.
echo "w" | fdisk "$DEVICE" > /dev/null 2>&1

parted "${DEVICE}" ---pretend-input-tty <<EOF
resizepart
${PARTNUM}
Yes
100%
quit
EOF

# 2. Run Parted with a "Logic Chain"
# We use the -s (script) flag for the actual resize. 
# If it fails, we fall back to the interactive mode with forced inputs.
#if ! parted -s "$DEVICE" resizepart "$PARTNUM" 100% 2>/dev/null; then
#    echo "Partition busy or GPT mismatched. Applying interactive fix..."
    
    # This sends a string of potential answers. 
    # By separating them, parted will consume them as prompts appear.
    # We include '3' again because resizepart might re-ask for it after a Fix.
    #printf "Fix\n$PARTNUM\nYes\n100%%\n" | parted ---pretend-input-tty "$DEVICE" resizepart
#    printf "Fix\n$PARTNUM\nYes\n100%%\n" | parted ---pretend-input-tty "$DEVICE" resizepart
#fi


# We pipe the responses 'Fix' and 'Yes' directly into the command.
# 'Fix' handles the GPT header mismatch.
# 'Yes' handles the 'Partition is being used' warning.
#printf "Fix\nYes\n" | sudo parted ---pretend-input-tty "${DEVICE}" resizepart "${PARTNUM}" 100%

#sudo parted "${DEVICE}" -- resizepart ${PARTNUM} 100%

# This sends 'w' (write) to fdisk. 
# fdisk automatically relocates the backup GPT header to the end of the disk on write.
#printf "w\n" | fdisk /dev/mmcblk0 > /dev/null 2>&1

# Now parted will be "silent" and won't ask for a Fix
#parted "${DEVICE}" ---pretend-input-tty <<EOF
#resizepart
#${PARTNUM}
#Yes
#100%
#quit
#EOF

#######################################################

# Attempt to print the partition table in script mode.
# If it needs fixing, parted will output a 'Warning' to stderr.
#CHECK_FIX=$(sudo parted -s "${DEVICE}" print 2>&1)

#if echo "$CHECK_FIX" | grep -q "not at the end of the disk"; then
#    echo "Detection: Fix is REQUIRED"
#    FIX_INPUT="Fix"
#else
#    echo "Detection: Disk is healthy"
#    FIX_INPUT=""
#fi

# Now run your command using the dynamically generated variable
#parted "${DEVICE}" ---pretend-input-tty <<EOF
#resizepart
#${FIX_INPUT}
#${PARTNUM}
#Yes
#100%
#quit
#EOF

#######################################################

#parted "${DEVICE}" ---pretend-input-tty <<EOF
#resizepart
#Fix
#${PARTNUM}
#Yes
#100%
#quit
#EOF

PARTED_STATUS=$?

# Check the status immediately
if [ $PARTED_STATUS -ne 0 ]; then
  printf "\e[31mERROR: parted failed with status %s.\e[0m\n" "$PARTED_STATUS"
  exit;
fi

# Use resize2fs to expand the filesystem to the new partition size.
echo "Resizing the filesystem on ${ROOT_PARTITION}..."
partprobe "$DEVICE"
resize2fs "${ROOT_PARTITION}"


df -h | grep /dev/mmcblk0p3 | awk '{ printf "New size \033[32m%s\033[0m\n", $2 }'

echo "Root partition and filesystem resized successfully."
echo "Rebooting to apply changes..."

# Reboot the system to ensure all changes are applied correctly.
sudo reboot

# Below is prompt from parted.
# Warning: Not all of the space available to /dev/mmcblk0 appears to be used, you can fix the GPT to use all of the space (an extra 15265792 blocks) or continue with
# the current setting? 
# Fix/Ignore? f                                                             
# Partition number? 3                                                       
# Warning: Partition /dev/mmcblk0p3 is being used. Are you sure you want to continue?
# Yes/No? y                                                                 
# End?  [7818MB]? 100%           