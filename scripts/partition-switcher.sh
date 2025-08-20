#!/bin/sh
# Universal A/B partition switcher

switch_to_partition() {
    TARGET_PART="$1"
    
    if [ "$TARGET_PART" = "A" ]; then
        TARGET_DEV="/dev/mmcblk0p2"
    elif [ "$TARGET_PART" = "B" ]; then
        TARGET_DEV="/dev/mmcblk0p3"
    else
        echo "Invalid partition: $TARGET_PART (use A or B)"
        exit 1
    fi
    
    echo "Switching to partition $TARGET_PART ($TARGET_DEV)"
    
    # Update cmdline.txt
    sed -i "s|root=/dev/mmcblk0p[23]|root=$TARGET_DEV|" /boot/cmdline.txt
    
    # Update active partition marker
    echo "$TARGET_PART" > /boot/active_partition
    echo "0" > "/boot/boot_attempts_$TARGET_PART"
    
    echo "Partition switch complete. Reboot to use partition $TARGET_PART"
}

# Main script
if [ $# -eq 0 ]; then
    echo "Usage: $0 <A|B>"
    echo "Current partition: $(cat /boot/active_partition 2>/dev/null || echo 'Unknown')"
    exit 1
fi

switch_to_partition "$1"
