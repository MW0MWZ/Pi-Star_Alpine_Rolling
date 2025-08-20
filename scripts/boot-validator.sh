#!/bin/sh
# Boot success validation

# Wait for system to stabilize
sleep 60

ACTIVE_PARTITION=$(cat /boot/active_partition 2>/dev/null || echo "A")
ATTEMPTS_FILE="/boot/boot_attempts_${ACTIVE_PARTITION}"

# Increment boot attempts
ATTEMPTS=$(cat "$ATTEMPTS_FILE" 2>/dev/null || echo "0")
ATTEMPTS=$((ATTEMPTS + 1))
echo "$ATTEMPTS" > "$ATTEMPTS_FILE"

# Check if too many failures
if [ "$ATTEMPTS" -gt "3" ]; then
    echo "Too many boot failures, rolling back"
    if [ "$ACTIVE_PARTITION" = "A" ]; then
        TARGET="B"
        TARGET_DEV="/dev/mmcblk0p3"
    else
        TARGET="A"
        TARGET_DEV="/dev/mmcblk0p2"
    fi
    
    sed -i "s|root=/dev/mmcblk0p[23]|root=$TARGET_DEV|" /boot/cmdline.txt
    echo "$TARGET" > /boot/active_partition
    echo "0" > "/boot/boot_attempts_$TARGET"
    reboot
    exit 1
fi

# Health check: Basic system + network
if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    # Success!
    echo "0" > "$ATTEMPTS_FILE"
    echo "Boot validation successful"
else
    echo "Boot validation failed"
fi
