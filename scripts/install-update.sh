#!/bin/sh
# Pi-Star Update Installer

UPDATE_FILE="$1"
NEW_VERSION="$2"

if [ ! -f "$UPDATE_FILE" ]; then
    echo "Update file not found: $UPDATE_FILE"
    exit 1
fi

# Determine current and target partitions
CURRENT_PART=$(cat /boot/active_partition 2>/dev/null || echo "A")
if [ "$CURRENT_PART" = "A" ]; then
    TARGET_PART="B"
    TARGET_DEV="/dev/mmcblk0p3"
else
    TARGET_PART="A"
    TARGET_DEV="/dev/mmcblk0p2"
fi

echo "Installing update to partition $TARGET_PART ($TARGET_DEV)"

# Mount target partition
mkdir -p /mnt/update
if ! mount "$TARGET_DEV" /mnt/update; then
    echo "Failed to mount $TARGET_DEV"
    exit 1
fi

# Backup critical data
mkdir -p /mnt/update/.update-backup
cp -r /opt/pi-star/data/* /mnt/update/.update-backup/ 2>/dev/null || true

# Clear partition and extract update
echo "Extracting update..."
rm -rf /mnt/update/*
tar -xzf "$UPDATE_FILE" -C /mnt/update/

# Restore user data
if [ -d "/mnt/update/.update-backup" ]; then
    mkdir -p /mnt/update/opt/pi-star/data
    cp -r /mnt/update/.update-backup/* /mnt/update/opt/pi-star/data/
    rm -rf /mnt/update/.update-backup
fi

# Update version info
echo "$NEW_VERSION" > /mnt/update/etc/pi-star-version

# Fix fstab for new partition
sed -i "s|/dev/mmcblk0p[23]|$TARGET_DEV|g" /mnt/update/etc/fstab

umount /mnt/update

# Switch boot partition
echo "Switching to partition $TARGET_PART"
sed -i "s|root=/dev/mmcblk0p[23]|root=$TARGET_DEV|" /boot/cmdline.txt
echo "$TARGET_PART" > /boot/active_partition
echo "0" > "/boot/boot_attempts_$TARGET_PART"

echo "Update installed. Rebooting in 5 seconds..."
sleep 5
reboot
