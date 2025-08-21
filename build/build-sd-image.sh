#!/bin/bash
set -e

VERSION="$1"
OUTPUT_FILE="${2:-pi-star-${VERSION}.img}"
IMAGE_SIZE="${IMAGE_SIZE:-2048M}"  # Changed from 4G to 2048M (2GB)
BUILD_DIR="${BUILD_DIR:-/tmp/pi-star-image-build}"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [output_file]"
    echo "Example: $0 2024.01.15 pi-star-2024.01.15.img"
    exit 1
fi

echo "Building Pi-Star SD card image v${VERSION}"
echo "Output: $OUTPUT_FILE"
echo "Size: $IMAGE_SIZE (optimized for 2GB SD cards)"

# Ensure we're running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root (needed for loop devices and mounting)"
    exit 1
fi

# Create build directory
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Create empty image file - 2GB instead of 4GB
echo "Creating ${IMAGE_SIZE} disk image..."
dd if=/dev/zero of="$OUTPUT_FILE" bs=1M count=0 seek=2048 status=progress

# Set up loop device
LOOP_DEVICE=$(losetup -f)
losetup "$LOOP_DEVICE" "$OUTPUT_FILE"
echo "Using loop device: $LOOP_DEVICE"

# Ensure we clean up on exit
cleanup() {
    echo "Cleaning up..."
    umount "${BUILD_DIR}/mnt"/* 2>/dev/null || true
    rmdir "${BUILD_DIR}/mnt"/* 2>/dev/null || true
    losetup -d "$LOOP_DEVICE" 2>/dev/null || true
}
trap cleanup EXIT

# Create partition table and partitions for 2GB SD card
echo "Creating partition table for 2GB SD card..."
parted -s "$LOOP_DEVICE" mklabel msdos

echo "Creating optimized partitions..."
# Boot partition - 128MB (1MiB to 129MiB)
parted -s "$LOOP_DEVICE" mkpart primary fat32 1MiB 129MiB

# RootFS-A - 650MB (129MiB to 779MiB)  
parted -s "$LOOP_DEVICE" mkpart primary ext4 129MiB 779MiB

# RootFS-B - 650MB (779MiB to 1429MiB)
parted -s "$LOOP_DEVICE" mkpart primary ext4 779MiB 1429MiB

# Data partition - 500MB (1429MiB to 1929MiB)
parted -s "$LOOP_DEVICE" mkpart primary ext4 1429MiB 1929MiB

# Set boot flag
parted -s "$LOOP_DEVICE" set 1 boot on

# Force kernel to re-read partition table
partprobe "$LOOP_DEVICE"
sleep 2

# Format partitions with optimized settings for smaller size
echo "Formatting boot partition (128MB)..."
mkfs.vfat -F 32 -n "PISTAR_BOOT" -S 512 "${LOOP_DEVICE}p1"

echo "Formatting RootFS-A partition (650MB)..."
mkfs.ext4 -F -L "PISTAR_ROOT_A" -m 1 -O ^has_journal,^resize_inode "${LOOP_DEVICE}p2"

echo "Formatting RootFS-B partition (650MB)..."  
mkfs.ext4 -F -L "PISTAR_ROOT_B" -m 1 -O ^has_journal,^resize_inode "${LOOP_DEVICE}p3"

echo "Formatting data partition (500MB)..."
mkfs.ext4 -F -L "PISTAR_DATA" -m 1 -O ^resize_inode "${LOOP_DEVICE}p4"

# Optimization notes:
# -m 1: Reduce reserved space from 5% to 1%
# -O ^has_journal: Disable journaling for root partitions (they're replaceable)
# -O ^resize_inode: Disable resize inode (saves space, we don't need online resize)
# Data partition keeps journaling for safety but disables resize_inode

# Wait for filesystem creation to complete and sync
sync
sleep 2

# Create mount points
mkdir -p mnt/boot mnt/root-a mnt/root-b mnt/data

# Mount partitions
echo "Mounting partitions..."
mount "${LOOP_DEVICE}p1" mnt/boot
mount "${LOOP_DEVICE}p2" mnt/root-a
mount "${LOOP_DEVICE}p3" mnt/root-b
mount "${LOOP_DEVICE}p4" mnt/data

# Install Raspberry Pi firmware to boot partition
echo "Installing Raspberry Pi firmware..."
if [ ! -d "rpi-firmware" ]; then
    git clone --depth=1 https://github.com/raspberrypi/firmware.git rpi-firmware
fi

# Copy only essential firmware files to save space
echo "Installing minimal firmware files..."
cp rpi-firmware/boot/bootcode.bin mnt/boot/
cp rpi-firmware/boot/start*.elf mnt/boot/
cp rpi-firmware/boot/fixup*.dat mnt/boot/

# Install kernel files
cp rpi-firmware/boot/kernel7l.img mnt/boot/  # Pi 4 32-bit kernel
cp rpi-firmware/boot/kernel7.img mnt/boot/   # Pi 2/3 32-bit kernel  
cp rpi-firmware/boot/kernel.img mnt/boot/    # Pi 1/Zero kernel

# Copy essential device tree files only
cp rpi-firmware/boot/bcm27*.dtb mnt/boot/
mkdir -p mnt/boot/overlays
cp rpi-firmware/boot/overlays/README mnt/boot/overlays/
# Copy only commonly used overlays to save space
cp rpi-firmware/boot/overlays/{gpio-*,spi*,i2c*,uart*,disable-*}.dtbo mnt/boot/overlays/ 2>/dev/null || true

# Install kernel modules to both root partitions (if available)
echo "Installing kernel modules..."
if [ -d "rpi-firmware/modules" ]; then
    cp -r rpi-firmware/modules/* mnt/root-a/lib/modules/ 2>/dev/null || true
    cp -r rpi-firmware/modules/* mnt/root-b/lib/modules/ 2>/dev/null || true
fi

# Create basic config.txt for Raspberry Pi (32-bit, optimized)
cat > mnt/boot/config.txt << 'EOF'
# Pi-Star Configuration (32-bit ARM, optimized for 2GB SD)
enable_uart=1
gpu_mem=16

# HDMI (basic support)
hdmi_force_hotplug=1

# Audio
dtparam=audio=on

# GPIO
dtparam=spi=on
dtparam=i2c_arm=on

# Disable unused features to save memory/boot time
disable_splash=1
boot_delay=0
EOF

# Create initial cmdline.txt (will boot to slot A)
echo "console=serial0,115200 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 elevator=deadline fsck.repair=yes rootwait quiet logo.nologo" > mnt/boot/cmdline.txt

# Create A/B state file (start with slot A)
echo "A" > mnt/boot/ab_state

# Install Pi-Star system to BOTH partitions
echo "Installing Pi-Star system to slot A..."
if [ -f "/tmp/pi-star-build/rootfs.tar.gz" ]; then
    tar -xzf "/tmp/pi-star-build/rootfs.tar.gz" -C mnt/root-a/
elif [ -d "/tmp/pi-star-build/rootfs" ]; then
    cp -a /tmp/pi-star-build/rootfs/* mnt/root-a/
else
    echo "Error: No Pi-Star rootfs found. Run build-rootfs.sh first."
    exit 1
fi

echo "Installing Pi-Star system to slot B (identical copy)..."
cp -a mnt/root-a/* mnt/root-b/

# Set up persistent data directory structure (minimal)
echo "Setting up minimal data partition..."
mkdir -p mnt/data/{config,logs,database}

# Create sample configuration file on boot partition
cat > mnt/boot/pistar-config.txt.sample << 'EOF'
# Pi-Star Boot Configuration Example
# Rename this file to 'pistar-config.txt' and edit as needed

# WiFi Configuration
#wifi_ssid=YourWiFiNetwork
#wifi_password=YourWiFiPassword
#wifi_country=GB

# User Security
#user_password=YourSecurePassword
#ssh_key=ssh-rsa AAAAB3NzaC1yc2EAAAA... your-email@example.com

# System Settings
#hostname=pi-star
#timezone=Europe/London

# Pi-Star Settings
#callsign=M0ABC
#dmr_id=1234567
EOF

# Create fstab for both root filesystems
create_fstab() {
    local root_dir="$1"
    cat > "${root_dir}/etc/fstab" << 'EOF'
# Pi-Star A/B Partition Layout (2GB optimized)
LABEL=PISTAR_BOOT     /boot           vfat    defaults,noatime                    0 2
LABEL=PISTAR_DATA     /opt/pistar     ext4    defaults,noatime                    0 2

# Bind mounts for Pi-Star integration
/opt/pistar/config    /etc/pistar     none    bind,nofail                         0 0
/opt/pistar/logs      /var/log/pistar none    bind,nofail                         0 0

# Temporary filesystem
tmpfs                 /tmp            tmpfs   nodev,nosuid,size=50M               0 0
EOF
}

create_fstab "mnt/root-a"
create_fstab "mnt/root-b"

# Set version in both partitions
echo "$VERSION" > mnt/root-a/etc/pi-star-version
echo "$VERSION" > mnt/root-b/etc/pi-star-version

# [Include first-boot-setup script from previous artifact]

# Unmount all partitions
echo "Unmounting partitions..."
umount mnt/boot mnt/root-a mnt/root-b mnt/data

# Detach loop device
losetup -d "$LOOP_DEVICE"

# Compress the image
echo "Compressing image..."
gzip "$OUTPUT_FILE"

echo ""
echo "2GB SD card image build complete!"
echo "Image: ${OUTPUT_FILE}.gz"
echo "Uncompressed size: $(ls -lh "${OUTPUT_FILE%.gz}" 2>/dev/null | awk '{print $5}' || echo 'Unknown')"
echo "Compressed size: $(ls -lh "${OUTPUT_FILE}.gz" | awk '{print $5}')"
echo ""
echo "PARTITION LAYOUT (2GB optimized):"
echo "  /dev/mmcblk0p1 - Boot (128MB, FAT32)"
echo "  /dev/mmcblk0p2 - Pi-Star Root A (650MB, ext4)"  
echo "  /dev/mmcblk0p3 - Pi-Star Root B (650MB, ext4)"
echo "  /dev/mmcblk0p4 - Persistent Data (500MB, ext4)"
echo ""
echo "Total used: ~1.93GB (fits on 2GB SD cards with room to spare)"
echo ""
echo "To flash to SD card (2GB+):"
echo "  gunzip -c ${OUTPUT_FILE}.gz | sudo dd of=/dev/sdX bs=4M status=progress"