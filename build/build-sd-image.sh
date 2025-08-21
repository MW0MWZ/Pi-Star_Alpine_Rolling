#!/bin/bash
set -e

VERSION="$1"
OUTPUT_FILE="${2:-pi-star-${VERSION}.img}"
IMAGE_SIZE="${IMAGE_SIZE:-4G}"  # 4GB image for smaller SD cards
BUILD_DIR="${BUILD_DIR:-/tmp/pi-star-image-build}"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [output_file]"
    echo "Example: $0 2024.01.15 pi-star-2024.01.15.img"
    exit 1
fi

echo "Building Pi-Star SD card image v${VERSION}"
echo "Output: $OUTPUT_FILE"
echo "Size: $IMAGE_SIZE"

# Ensure we're running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root (needed for loop devices and mounting)"
    exit 1
fi

# Create build directory
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Create empty image file
echo "Creating ${IMAGE_SIZE} disk image..."
dd if=/dev/zero of="$OUTPUT_FILE" bs=1M count=0 seek=4096 status=progress

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

echo "Creating optimized partitions for 2GB card..."
# Boot partition - 128MB (sufficient for Pi firmware + config)
parted -s "$LOOP_DEVICE" mkpart primary fat32 1MiB 129MiB

# RootFS-A - 650MB (minimal OS footprint)  
parted -s "$LOOP_DEVICE" mkpart primary ext4 129MiB 779MiB

# RootFS-B - 650MB (identical to A)
parted -s "$LOOP_DEVICE" mkpart primary ext4 779MiB 1429MiB

# Data partition - 500MB (Pi-Star config, logs, databases)
parted -s "$LOOP_DEVICE" mkpart primary ext4 1429MiB 1929MiB

# Set boot flag
parted -s "$LOOP_DEVICE" set 1 boot on

# Force kernel to re-read partition table
partprobe "$LOOP_DEVICE"
sleep 2

# Format partitions with optimized settings
echo "Formatting boot partition (128MB)..."
mkfs.vfat -F 32 -n "PISTAR_BOOT" -S 512 "${LOOP_DEVICE}p1"

echo "Formatting RootFS-A partition (650MB)..."
mkfs.ext4 -F -L "PISTAR_ROOT_A" -m 1 -O ^has_journal "${LOOP_DEVICE}p2"

echo "Formatting RootFS-B partition (650MB)..."  
mkfs.ext4 -F -L "PISTAR_ROOT_B" -m 1 -O ^has_journal "${LOOP_DEVICE}p3"

echo "Formatting data partition (500MB)..."
mkfs.ext4 -F -L "PISTAR_DATA" -m 1 "${LOOP_DEVICE}p4"

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

# Copy firmware files
cp rpi-firmware/boot/*.bin mnt/boot/
cp rpi-firmware/boot/*.dat mnt/boot/
cp rpi-firmware/boot/*.elf mnt/boot/

# Install kernel and device tree files
echo "Installing Raspberry Pi kernel..."
# For 32-bit ARM (armhf)
cp rpi-firmware/boot/kernel7l.img mnt/boot/  # Pi 4 32-bit kernel
cp rpi-firmware/boot/kernel7.img mnt/boot/   # Pi 2/3 32-bit kernel  
cp rpi-firmware/boot/kernel.img mnt/boot/    # Pi 1/Zero kernel

# Copy device tree files
cp rpi-firmware/boot/*.dtb mnt/boot/
cp -r rpi-firmware/boot/overlays mnt/boot/

# Install kernel modules to both root partitions
echo "Installing kernel modules..."
if [ -d "rpi-firmware/modules" ]; then
    # Copy modules to both root partitions
    cp -r rpi-firmware/modules/* mnt/root-a/lib/modules/ 2>/dev/null || true
    cp -r rpi-firmware/modules/* mnt/root-b/lib/modules/ 2>/dev/null || true
fi

# Create basic config.txt for Raspberry Pi (32-bit)
cat > mnt/boot/config.txt << 'EOF'
# Pi-Star Configuration (32-bit ARM)
# arm_64bit=1  # Disabled for 32-bit
enable_uart=1
gpu_mem=16

# HDMI
hdmi_force_hotplug=1
hdmi_drive=2

# Audio
dtparam=audio=on

# GPIO
dtparam=spi=on
dtparam=i2c_arm=on

# Enable camera (if needed)
# start_x=1

# Overclock (optional)
# arm_freq=1500
# gpu_freq=500
EOF

# Create initial cmdline.txt (will boot to slot A)
# Use device path for reliability, but include rootwait for label detection
echo "console=serial0,115200 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 elevator=deadline fsck.repair=yes rootwait quiet" > mnt/boot/cmdline.txt

# Create A/B state file (start with slot A)
echo "A" > mnt/boot/ab_state

# Install Pi-Star system to BOTH partitions (A and B identical initially)
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

# Set up persistent data directory structure
echo "Setting up data partition..."
mkdir -p mnt/data/{config,logs,database,backup}

# Create fstab for both root filesystems
create_fstab() {
    local root_dir="$1"
    cat > "${root_dir}/etc/fstab" << 'EOF'
# Pi-Star A/B Partition Layout
LABEL=PISTAR_BOOT     /boot           vfat    defaults,noatime                    0 2
LABEL=PISTAR_DATA     /opt/pistar     ext4    defaults,noatime                    0 2

# Bind mounts for persistent data
/opt/pistar/config    /etc/pistar     none    bind                                0 0
/opt/pistar/logs      /var/log        none    bind                                0 0
EOF
}

create_fstab "mnt/root-a"
create_fstab "mnt/root-b"

# Copy boot manager script to both partitions
if [ -f "scripts/boot-manager.sh" ]; then
    cp scripts/boot-manager.sh mnt/root-a/usr/local/bin/boot-manager
    cp scripts/boot-manager.sh mnt/root-b/usr/local/bin/boot-manager
    chmod +x mnt/root-a/usr/local/bin/boot-manager
    chmod +x mnt/root-b/usr/local/bin/boot-manager
fi

# Set version in both partitions
echo "$VERSION" > mnt/root-a/etc/pi-star-version
echo "$VERSION" > mnt/root-b/etc/pi-star-version

# Create first-boot setup script
cat > mnt/root-a/usr/local/bin/first-boot-setup << 'EOF'
#!/bin/bash
# First boot setup for Pi-Star A/B system

echo "Pi-Star First Boot Setup"
echo "======================="

# Check if running interactively
if [ -t 0 ]; then
    echo ""
    echo "Default login credentials:"
    echo "  Username: pi-star"
    echo "  Password: pi-star"
    echo ""
    echo "  Root password: pistar"
    echo ""
    echo "SECURITY WARNING: Please change these default passwords!"
    echo ""
    
    # Offer to change passwords
    read -p "Would you like to change the pi-star password now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        passwd pi-star
    fi
    
    read -p "Would you like to change the root password now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        passwd root
    fi
fi

# Mark A/B boot slot as successful
/usr/local/bin/boot-manager success A

# Mark first boot complete
touch /opt/pistar/.first-boot-complete

echo "Pi-Star A/B system first boot complete"
EOF

chmod +x mnt/root-a/usr/local/bin/first-boot-setup
cp mnt/root-a/usr/local/bin/first-boot-setup mnt/root-b/usr/local/bin/first-boot-setup

# Enable first boot service in both partitions
cat > mnt/root-a/etc/init.d/first-boot << 'EOF'
#!/sbin/openrc-run

name="First Boot Setup"
description="Pi-Star first boot configuration"
command="/usr/local/bin/first-boot-setup"

depend() {
    after localmount
    before networking
}

start() {
    if [ ! -f /opt/pistar/.first-boot-complete ]; then
        ebegin "Running first boot setup"
        $command
        eend $?
    fi
}
EOF

chmod +x mnt/root-a/etc/init.d/first-boot
cp mnt/root-a/etc/init.d/first-boot mnt/root-b/etc/init.d/first-boot

# Enable first-boot service in both partitions (using chroot)
chroot mnt/root-a rc-update add first-boot boot
chroot mnt/root-b rc-update add first-boot boot

# Unmount all partitions
echo "Unmounting partitions..."
umount mnt/boot mnt/root-a mnt/root-b mnt/data

# Detach loop device
losetup -d "$LOOP_DEVICE"

# Compress the image
echo "Compressing image..."
gzip "$OUTPUT_FILE"

echo ""
echo "SD card image build complete!"
echo "Image: ${OUTPUT_FILE}.gz"
echo "Size: $(ls -lh "${OUTPUT_FILE}.gz" | awk '{print $5}')"
echo ""
echo "DEFAULT LOGIN CREDENTIALS:"
echo "  Username: pi-star"
echo "  Password: pi-star"
echo ""
echo "  Root username: root"
echo "  Root password: pistar"
echo ""
echo "⚠️  SECURITY: Change these passwords on first boot!"
echo ""
echo "To flash to SD card (4GB+):"
echo "  gunzip -c ${OUTPUT_FILE}.gz | sudo dd of=/dev/sdX bs=4M status=progress"
echo ""
echo "Partition layout (fits on 4GB SD card):"
echo "  /dev/mmcblk0p1 - Boot (256MB, FAT32)"
echo "  /dev/mmcblk0p2 - Pi-Star Root A (1GB, ext4)"  
echo "  /dev/mmcblk0p3 - Pi-Star Root B (1GB, ext4)"
echo "  /dev/mmcblk0p4 - Persistent Data (500MB, ext4)"
echo ""
echo "Total used: ~2.75GB (fits comfortably in 4GB)"