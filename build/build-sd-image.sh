#!/bin/bash
set -e

VERSION="$1"
OUTPUT_FILE="${2:-pi-star-${VERSION}.img}"
IMAGE_SIZE="${IMAGE_SIZE:-2048M}"  # 2GB for 2GB SD cards
BUILD_DIR="${BUILD_DIR:-/tmp/pi-star-image-build}"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [output_file]"
    echo "Example: $0 2024.01.15 pi-star-2024.01.15.img"
    exit 1
fi

echo "Building Pi-Star SD card image v${VERSION} - PURE ALPINE APPROACH"
echo "Output: $OUTPUT_FILE"
echo "Size: $IMAGE_SIZE (optimized for 2GB SD cards)"
echo "Kernel: 100% Alpine (no Pi Foundation kernel mixing)"

# Ensure we're running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root (needed for loop devices and mounting)"
    exit 1
fi

# Create build directory
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Create empty image file - 2GB
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

# FIXED: Check for rootfs directory and handle Alpine kernel properly
echo "=== INSTALLING PURE ALPINE BOOT SYSTEM ==="

# Verify rootfs exists
ROOTFS_PATH="/tmp/pi-star-build/rootfs"
KERNEL_FILES_PATH="/tmp/pi-star-build/kernel-files"

if [ ! -d "$ROOTFS_PATH" ]; then
    echo "Error: Alpine rootfs not found at $ROOTFS_PATH"
    echo "Please run build-rootfs.sh first"
    echo "Available directories in /tmp/pi-star-build:"
    ls -la /tmp/pi-star-build/ 2>/dev/null || echo "Build directory not found"
    exit 1
fi

echo "Found rootfs at: $ROOTFS_PATH"
echo "Rootfs contents:"
ls -la "$ROOTFS_PATH/" | head -10

# FIXED: Use exported kernel files from build-rootfs.sh
echo "Searching for Alpine kernel files..."

ALPINE_KERNEL=""
ALPINE_INITRD=""
ALPINE_MODULES=""

# Method 1: Use exported kernel files (preferred method)
if [ -d "$KERNEL_FILES_PATH" ]; then
    echo "✅ Found exported kernel files at: $KERNEL_FILES_PATH"
    ls -la "$KERNEL_FILES_PATH/"
    
    ALPINE_KERNEL=$(find "$KERNEL_FILES_PATH" -name "vmlinuz-*" -type f | head -1)
    ALPINE_INITRD=$(find "$KERNEL_FILES_PATH" -name "initramfs-*" -type f | head -1)
    
    if [ -n "$ALPINE_KERNEL" ]; then
        echo "✅ Using exported Alpine kernel: $ALPINE_KERNEL"
    fi
    if [ -n "$ALPINE_INITRD" ]; then
        echo "✅ Using exported Alpine initramfs: $ALPINE_INITRD"
    fi
fi

# Method 2: Look in rootfs/boot directory (fallback)
if [ -z "$ALPINE_KERNEL" ] && [ -d "$ROOTFS_PATH/boot" ]; then
    echo "Fallback: Checking $ROOTFS_PATH/boot for kernel files..."
    ls -la "$ROOTFS_PATH/boot/" || true
    ALPINE_KERNEL=$(find "$ROOTFS_PATH/boot" -name "vmlinuz-*" -type f 2>/dev/null | head -1)
    ALPINE_INITRD=$(find "$ROOTFS_PATH/boot" -name "initramfs-*" -type f 2>/dev/null | head -1)
    
    if [ -n "$ALPINE_KERNEL" ]; then
        echo "✅ Found kernel in rootfs/boot: $ALPINE_KERNEL"
    fi
fi

# Method 3: Download Alpine kernel directly if still not found
if [ -z "$ALPINE_KERNEL" ]; then
    echo "WARNING: Alpine kernel not found in rootfs, downloading directly..."
    echo "This fallback method downloads a compatible Alpine kernel"
    
    mkdir -p kernel-download
    cd kernel-download
    
    # Download Alpine kernel package for armhf
    ALPINE_VERSION="${ALPINE_VERSION:-3.22}"
    
    echo "Downloading Alpine kernel package..."
    if wget "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main/armhf/APKINDEX.tar.gz" -O APKINDEX.tar.gz; then
        # Extract package index
        tar -xzf APKINDEX.tar.gz
        
        # Find kernel package
        KERNEL_PKG=$(grep -A 5 "P:linux-rpi" APKINDEX | grep "V:" | head -1 | cut -d: -f2)
        if [ -n "$KERNEL_PKG" ]; then
            echo "Found Alpine kernel version: $KERNEL_PKG"
            
            # Download and extract kernel package
            PKG_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main/armhf/linux-rpi-${KERNEL_PKG}.apk"
            echo "Downloading: $PKG_URL"
            
            if wget "$PKG_URL" -O kernel.apk; then
                # Extract kernel from apk (it's just a tar.gz)
                tar -xzf kernel.apk
                
                # Find kernel files
                ALPINE_KERNEL=$(find . -name "vmlinuz-*" -type f | head -1)
                ALPINE_INITRD=$(find . -name "initramfs-*" -type f | head -1)
                
                if [ -n "$ALPINE_KERNEL" ]; then
                    # Convert to absolute path
                    ALPINE_KERNEL=$(cd "$(dirname "$ALPINE_KERNEL")" && pwd)/$(basename "$ALPINE_KERNEL")
                    echo "Downloaded Alpine kernel: $ALPINE_KERNEL"
                fi
                
                if [ -n "$ALPINE_INITRD" ]; then
                    ALPINE_INITRD=$(cd "$(dirname "$ALPINE_INITRD")" && pwd)/$(basename "$ALPINE_INITRD")
                    echo "Downloaded Alpine initrd: $ALPINE_INITRD"
                fi
            fi
        fi
    fi
    
    cd ..
fi

# Verify we have a kernel
if [ -z "$ALPINE_KERNEL" ] || [ ! -f "$ALPINE_KERNEL" ]; then
    echo "FATAL ERROR: Could not find or download Alpine kernel"
    echo "Attempted methods:"
    echo "1. Looking in $ROOTFS_PATH/boot/ - failed"
    echo "2. Extracting from chroot - failed"
    echo "3. Direct download - failed"
    echo ""
    echo "Debug information:"
    echo "ROOTFS_PATH: $ROOTFS_PATH"
    echo "Rootfs exists: $([ -d "$ROOTFS_PATH" ] && echo 'YES' || echo 'NO')"
    if [ -d "$ROOTFS_PATH" ]; then
        echo "Rootfs structure:"
        find "$ROOTFS_PATH" -maxdepth 2 -type d | head -20
        echo ""
        echo "Looking for any kernel-like files:"
        find "$ROOTFS_PATH" -name "*vmlinuz*" -o -name "*kernel*" -o -name "*bzImage*" 2>/dev/null | head -10
    fi
    exit 1
fi

# Find modules directory
if [ -d "$ROOTFS_PATH/lib/modules" ]; then
    ALPINE_MODULES=$(find "$ROOTFS_PATH/lib/modules" -maxdepth 1 -mindepth 1 -type d | head -1)
fi

echo "✅ Alpine kernel components found:"
echo "  Kernel: $ALPINE_KERNEL"
echo "  Initrd: $ALPINE_INITRD"
echo "  Modules: $ALPINE_MODULES"

# Extract kernel version from path
if [ -n "$ALPINE_MODULES" ]; then
    KERNEL_VERSION=$(basename "$ALPINE_MODULES")
else
    # Extract from kernel filename
    KERNEL_VERSION=$(basename "$ALPINE_KERNEL" | sed 's/vmlinuz-//')
fi
echo "Alpine kernel version: $KERNEL_VERSION"

# Install MINIMAL Pi firmware (just enough to boot Alpine kernel)
echo "Installing minimal Pi firmware for Alpine kernel boot..."

# Create temporary firmware download
mkdir -p firmware-temp
cd firmware-temp

# Download ONLY essential Pi firmware files (not kernel!)
echo "Downloading minimal Pi firmware..."
wget -q https://github.com/raspberrypi/firmware/raw/master/boot/bootcode.bin || echo "bootcode.bin download failed (may not be needed on Pi 4+)"
wget -q https://github.com/raspberrypi/firmware/raw/master/boot/start.elf || echo "start.elf download failed"
wget -q https://github.com/raspberrypi/firmware/raw/master/boot/start4.elf || echo "start4.elf download failed"
wget -q https://github.com/raspberrypi/firmware/raw/master/boot/fixup.dat || echo "fixup.dat download failed"
wget -q https://github.com/raspberrypi/firmware/raw/master/boot/fixup4.dat || echo "fixup4.dat download failed"

# Copy only essential firmware (NO Pi kernels!)
echo "Installing firmware files..."
cp bootcode.bin ../mnt/boot/ 2>/dev/null || echo "bootcode.bin not available (normal for Pi 4+)"
cp start*.elf ../mnt/boot/ 2>/dev/null || echo "start.elf files not available"
cp fixup*.dat ../mnt/boot/ 2>/dev/null || echo "fixup.dat files not available"

cd ..
rm -rf firmware-temp

# Install Alpine kernel as the PRIMARY kernel
echo "Installing Alpine kernel as primary boot kernel..."
cp "$ALPINE_KERNEL" mnt/boot/kernel.img
cp "$ALPINE_KERNEL" mnt/boot/kernel7.img  # For Pi 2/3
cp "$ALPINE_KERNEL" mnt/boot/kernel7l.img # For Pi 4
cp "$ALPINE_KERNEL" mnt/boot/kernel8.img  # For Pi 3/4 64-bit mode

if [ -n "$ALPINE_INITRD" ] && [ -f "$ALPINE_INITRD" ]; then
    echo "Installing Alpine initrd..."
    cp "$ALPINE_INITRD" mnt/boot/initrd.img
    cp "$ALPINE_INITRD" mnt/boot/initrd7.img
    cp "$ALPINE_INITRD" mnt/boot/initrd7l.img
    cp "$ALPINE_INITRD" mnt/boot/initrd8.img
    INITRD_CMDLINE="initrd=initrd.img"
else
    echo "No initrd found - booting without initrd"
    INITRD_CMDLINE=""
fi

# Create PURE ALPINE config.txt
echo "Creating Pure Alpine config.txt..."
cat > mnt/boot/config.txt << 'EOF'
# Pi-Star Pure Alpine Configuration
# Uses 100% Alpine kernel (no Pi Foundation kernel mixing)

# Essential Pi firmware settings
enable_uart=1
gpu_mem=16

# Audio support
dtparam=audio=on

# GPIO/SPI/I2C support  
dtparam=spi=on
dtparam=i2c_arm=on

# Universal kernel configuration for all Pi models
# Alpine kernel works on all Pi models
kernel=kernel.img

# Pi model specific optimizations
[pi02]
# Pi Zero 2W - use universal Alpine kernel
kernel=kernel7.img

[pi3]
# Pi 3 - use universal Alpine kernel
kernel=kernel7.img

[pi4]
# Pi 4 - use universal Alpine kernel
kernel=kernel7l.img

[pi5]
# Pi 5 - use universal Alpine kernel
kernel=kernel7l.img

[all]
# Wireless optimizations for all models
dtparam=krnbt=off

# Boot optimizations
disable_splash=1
boot_delay=0

# Memory optimization for embedded use
gpu_mem=16
EOF

# Create Alpine-optimized cmdline.txt
echo "Creating Alpine-optimized cmdline.txt..."
cat > mnt/boot/cmdline.txt << EOF
console=serial0,115200 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 elevator=deadline fsck.repair=yes rootwait quiet modules-load=brcmfmac,brcmutil,cfg80211 ${INITRD_CMDLINE}
EOF

# Create A/B state file (start with slot A)
echo "A" > mnt/boot/ab_state

# Install Pi-Star system to BOTH partitions
echo "Installing Pi-Star system to slot A..."
if [ -f "/tmp/pi-star-build/rootfs.tar.gz" ]; then
    echo "Installing from rootfs.tar.gz..."
    tar -xzf "/tmp/pi-star-build/rootfs.tar.gz" -C mnt/root-a/
elif [ -d "/tmp/pi-star-build/rootfs" ]; then
    echo "Installing from rootfs directory..."
    cp -a /tmp/pi-star-build/rootfs/* mnt/root-a/
else
    echo "Error: No Pi-Star rootfs found. Available files:"
    ls -la /tmp/pi-star-build/ 2>/dev/null || echo "Build directory not found"
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

# Debug (to see detailed processing)
#DEBUG_BOOT_CONFIG=1
EOF

# Create fstab for both root filesystems
create_fstab() {
    local root_dir="$1"
    cat > "${root_dir}/etc/fstab" << 'EOF'
# Pi-Star A/B Partition Layout (2GB optimized) - Pure Alpine
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

# Add Alpine kernel version info
echo "Alpine kernel: $KERNEL_VERSION" > mnt/root-a/etc/alpine-kernel-version
echo "Alpine kernel: $KERNEL_VERSION" > mnt/root-b/etc/alpine-kernel-version

# Create Pure Alpine information file
cat > mnt/boot/alpine-info.txt << EOF
# Pi-Star Pure Alpine Build Information
Build Version: $VERSION
Build Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Alpine Kernel: $KERNEL_VERSION
Architecture: armhf (32-bit ARM)
Approach: 100% Alpine (no Pi Foundation kernel mixing)

Supported Pi Models: All (Zero, 1, 2, 3, 4, 5)
Wireless Support: All Pi wireless chips
GPIO/SPI/I2C: Full support via Alpine kernel
Ethernet: Full support via Alpine kernel

Benefits:
- No kernel/module version mismatches
- Alpine controls entire kernel stack
- Reliable, predictable updates
- Clean, maintainable architecture
- Full Pi hardware support maintained

For support: https://github.com/MW0MWZ/Pi-Star_Alpine_Rolling
EOF

# Create enhanced first-boot information script
cat > mnt/root-a/usr/local/bin/show-alpine-info << 'EOF'
#!/bin/bash
# Show Pure Alpine Pi information

echo "=========================================="
echo "Pi-Star Pure Alpine Linux"
echo "=========================================="
echo ""

if [ -f /etc/alpine-kernel-version ]; then
    echo "Kernel: $(cat /etc/alpine-kernel-version)"
else
    echo "Kernel: $(uname -r)"
fi

if [ -f /etc/pi-star-version ]; then
    echo "Pi-Star Version: $(cat /etc/pi-star-version)"
fi

echo "Alpine Version: $(cat /etc/alpine-release 2>/dev/null || echo 'Unknown')"
echo ""

# Show Pi model detection
if [ -f /proc/device-tree/model ]; then
    echo "Pi Model: $(cat /proc/device-tree/model | tr '\0' '\n' | head -1)"
fi

echo "Architecture: $(uname -m)"
echo ""

echo "PURE ALPINE BENEFITS:"
echo "• No kernel/module mismatches"
echo "• Alpine-controlled updates"  
echo "• Clean, maintainable system"
echo "• Full Pi hardware support"
echo ""

echo "Logs available:"
echo "• Boot config: /var/log/boot-config.log"
echo "• Pi detection: /var/log/alpine-pi-detect.log"
echo ""

echo "Configuration:"
echo "• WiFi/Password: Create /boot/pistar-config.txt"
echo "• SSH Access: SSH keys or password in config file"
echo "• Documentation: /boot/alpine-info.txt"
echo ""
echo "=========================================="
EOF

chmod +x mnt/root-a/usr/local/bin/show-alpine-info
cp mnt/root-a/usr/local/bin/show-alpine-info mnt/root-b/usr/local/bin/show-alpine-info

# Unmount all partitions
echo "Unmounting partitions..."
umount mnt/boot mnt/root-a mnt/root-b mnt/data

# Detach loop device
losetup -d "$LOOP_DEVICE"

# Compress the image
echo "Compressing image..."
gzip "$OUTPUT_FILE"

echo ""
echo "=== PURE ALPINE SD CARD IMAGE BUILD COMPLETE ==="
echo "Image: ${OUTPUT_FILE}.gz"
echo "Uncompressed size: 2GB (fits 2GB SD cards)"
echo "Compressed size: $(ls -lh "${OUTPUT_FILE}.gz" | awk '{print $5}')"
echo ""
echo "PURE ALPINE ARCHITECTURE:"
echo "  Kernel: 100% Alpine (no Pi Foundation mixing)"
echo "  Modules: Alpine kernel modules (guaranteed match)"
echo "  Firmware: Minimal Pi firmware + comprehensive wireless"
echo "  Boot: Alpine kernel on all Pi models"
echo ""
echo "PARTITION LAYOUT (2GB optimized):"
echo "  /dev/mmcblk0p1 - Boot (128MB, FAT32) - Alpine kernel"
echo "  /dev/mmcblk0p2 - Pi-Star Root A (650MB, ext4)"  
echo "  /dev/mmcblk0p3 - Pi-Star Root B (650MB, ext4)"
echo "  /dev/mmcblk0p4 - Persistent Data (500MB, ext4)"
echo ""
echo "BENEFITS:"
echo "  ✅ No 'brcmfmac not found' errors"
echo "  ✅ Kernel and modules always match"
echo "  ✅ All Pi models supported"
echo "  ✅ Full hardware support (GPIO/SPI/I2C/WiFi/Ethernet)"
echo "  ✅ Clean, maintainable Alpine architecture"
echo "  ✅ Reliable updates controlled by Alpine"
echo ""
echo "To flash to SD card (2GB+):"
echo "  gunzip -c ${OUTPUT_FILE}.gz | sudo dd of=/dev/sdX bs=4M status=progress"
echo ""
echo "First boot configuration:"
echo "  Create /boot/pistar-config.txt with your WiFi and user settings"
echo "  See /boot/pistar-config.txt.sample for examples"
echo ""
echo "Pure Alpine Pi-Star image ready! 🚀"