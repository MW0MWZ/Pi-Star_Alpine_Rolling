#!/bin/bash
set -e

VERSION="$1"
OUTPUT_FILE="${2:-pi-star-${VERSION}.img}"
IMAGE_SIZE="${IMAGE_SIZE:-2048M}"
BUILD_DIR="${BUILD_DIR:-/tmp/pi-star-image-build}"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [output_file]"
    echo "Example: $0 2024.01.15 pi-star-2024.01.15.img"
    exit 1
fi

echo "🚀 Building Pi-Star SD card image v${VERSION} - ALPINE + RASPBIAN HYBRID"
echo "📁 Output: $OUTPUT_FILE"
echo "📏 Size: $IMAGE_SIZE (optimized for 2GB SD cards)"
echo "🔧 Architecture: Alpine userland + Raspbian kernel with A/B boot solution"

# Ensure we're running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root (needed for loop devices and mounting)"
    exit 1
fi

# Create build directory
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Create empty image file - 2GB
echo "💾 Creating ${IMAGE_SIZE} disk image..."
dd if=/dev/zero of="$OUTPUT_FILE" bs=1M count=0 seek=2048 status=progress

# Set up loop device
LOOP_DEVICE=$(losetup -f)
losetup "$LOOP_DEVICE" "$OUTPUT_FILE"
echo "🔗 Using loop device: $LOOP_DEVICE"

# Cleanup function
cleanup() {
    echo "🧹 Cleaning up..."
    umount "${BUILD_DIR}/mnt"/* 2>/dev/null || true
    rmdir "${BUILD_DIR}/mnt"/* 2>/dev/null || true
    losetup -d "$LOOP_DEVICE" 2>/dev/null || true
}
trap cleanup EXIT

# Create partition table for 2GB SD card with A/B boot solution
echo "🗂️ Creating partition table for A/B boot solution..."
parted -s "$LOOP_DEVICE" mklabel msdos

echo "📋 Creating optimized partitions for A/B updates..."
# Boot partition - 128MB (shared + A/B kernels)
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

# Format partitions
echo "💾 Formatting partitions..."
mkfs.vfat -F 32 -n "PISTAR_BOOT" -S 512 "${LOOP_DEVICE}p1"
mkfs.ext4 -F -L "PISTAR_ROOT_A" -m 1 -O ^has_journal,^resize_inode "${LOOP_DEVICE}p2"
mkfs.ext4 -F -L "PISTAR_ROOT_B" -m 1 -O ^has_journal,^resize_inode "${LOOP_DEVICE}p3"
mkfs.ext4 -F -L "PISTAR_DATA" -m 1 -O ^resize_inode "${LOOP_DEVICE}p4"

# Wait for filesystem creation to complete
sync
sleep 2

# Create mount points
mkdir -p mnt/boot mnt/root-a mnt/root-b mnt/data

# Mount partitions
echo "🔗 Mounting partitions..."
mount "${LOOP_DEVICE}p1" mnt/boot
mount "${LOOP_DEVICE}p2" mnt/root-a
mount "${LOOP_DEVICE}p3" mnt/root-b
mount "${LOOP_DEVICE}p4" mnt/data

# Verify rootfs exists
ROOTFS_PATH="/tmp/pi-star-build/rootfs"
KERNEL_FILES_PATH="/tmp/pi-star-build/kernel-files"

if [ ! -d "$ROOTFS_PATH" ]; then
    echo "❌ Error: Rootfs not found at $ROOTFS_PATH"
    echo "Please run build-rootfs.sh first"
    exit 1
fi

echo "✅ Found Alpine+Raspbian hybrid rootfs"

# Check kernel source
KERNEL_SOURCE=$(cat "$KERNEL_FILES_PATH/kernel_source.txt" 2>/dev/null || echo "unknown")
KERNEL_VERSION=$(cat "$KERNEL_FILES_PATH/kernel_version.txt" 2>/dev/null || echo "unknown")

echo "🚀 Installing hybrid system with $KERNEL_SOURCE kernel v$KERNEL_VERSION"

# =====================================================
# INSTALL SHARED BOOT PARTITION (Firmware + Active Kernel)
# =====================================================

echo "📡 Installing shared boot partition..."

# Install Pi firmware from hybrid rootfs
if [ -d "$ROOTFS_PATH/boot" ]; then
    echo "📋 Copying Pi firmware and kernels (FAT32 compatible)..."
    
    # Copy files one by one to avoid symlink issues on FAT32
    for item in "$ROOTFS_PATH/boot"/*; do
        if [ -f "$item" ]; then
            # Regular file - copy directly
            cp "$item" mnt/boot/
        elif [ -d "$item" ]; then
            # Directory - copy recursively, handling symlinks
            dirname=$(basename "$item")
            mkdir -p "mnt/boot/$dirname"
            find "$item" -type f -exec cp {} "mnt/boot/$dirname/" \; 2>/dev/null || true
        elif [ -L "$item" ]; then
            # Symlink - resolve and copy target if it exists
            target=$(readlink "$item")
            basename_item=$(basename "$item")
            
            # Try to find the actual file
            if [ -f "$target" ]; then
                cp "$target" "mnt/boot/$basename_item"
            elif [ -f "$ROOTFS_PATH/boot/$target" ]; then
                cp "$ROOTFS_PATH/boot/$target" "mnt/boot/$basename_item"
            elif [ -f "$(dirname "$item")/$target" ]; then
                cp "$(dirname "$item")/$target" "mnt/boot/$basename_item"
            else
                echo "⚠️  Skipping broken symlink: $basename_item -> $target"
            fi
        fi
    done
    
    echo "✅ Installed complete boot system:"
    echo "   • Pi firmware (start.elf, etc.)"
    echo "   • All Pi kernels (kernel.img, kernel7.img, etc.)"
    echo "   • Device trees for all Pi models"
    echo "   • Minimal overlays for Pi-Star"
else
    echo "❌ No boot directory found in rootfs"
    exit 1
fi

# =====================================================
# CREATE A/B KERNEL DIRECTORIES IN BOOT
# =====================================================

echo "🔄 Setting up A/B kernel structure..."

# Debug: Show what we actually have in boot
echo "🔍 Debugging: Boot partition contents:"
ls -la mnt/boot/ | head -20

# Create directories for A/B kernel storage
mkdir -p mnt/boot/kernelA
mkdir -p mnt/boot/kernelB

# Look for kernel files and copy them to A/B directories
KERNEL_FILES_FOUND=0

# Check for kernel files in boot directory
if ls mnt/boot/kernel*.img >/dev/null 2>&1; then
    echo "✅ Found kernel files in boot directory"
    cp mnt/boot/kernel*.img mnt/boot/kernelA/
    cp mnt/boot/kernel*.img mnt/boot/kernelB/
    KERNEL_FILES_FOUND=1
    echo "✅ Created A/B kernel directories with $(ls mnt/boot/kernel*.img | wc -l) kernels"
else
    echo "⚠️  No kernel*.img files found in boot directory"
    
    # Check if we have any kernel-like files
    echo "🔍 Looking for any kernel-related files..."
    find mnt/boot/ -name "*kernel*" -o -name "*vmlinuz*" -o -name "*zImage*" | head -10
    
    # Check the exported kernel files from rootfs build
    if [ -f "$KERNEL_FILES_PATH/kernel_source.txt" ]; then
        KERNEL_SOURCE=$(cat "$KERNEL_FILES_PATH/kernel_source.txt")
        echo "📋 Kernel source from build: $KERNEL_SOURCE"
        
        if [ -d "$KERNEL_FILES_PATH" ]; then
            echo "🔍 Available kernel files from rootfs build:"
            ls -la "$KERNEL_FILES_PATH/"
            
            # Try to copy from kernel files directory
            if ls "$KERNEL_FILES_PATH"/kernel*.img >/dev/null 2>&1; then
                echo "🔄 Copying kernels from kernel files directory..."
                cp "$KERNEL_FILES_PATH"/kernel*.img mnt/boot/
                cp "$KERNEL_FILES_PATH"/kernel*.img mnt/boot/kernelA/
                cp "$KERNEL_FILES_PATH"/kernel*.img mnt/boot/kernelB/
                KERNEL_FILES_FOUND=1
                echo "✅ Kernels copied from kernel files directory"
            elif ls "$KERNEL_FILES_PATH"/vmlinuz* >/dev/null 2>&1; then
                echo "🔄 Converting vmlinuz to kernel.img format..."
                for vmlinuz in "$KERNEL_FILES_PATH"/vmlinuz*; do
                    kernel_name=$(basename "$vmlinuz" | sed 's/vmlinuz/kernel/').img
                    cp "$vmlinuz" "mnt/boot/$kernel_name"
                done
                cp mnt/boot/kernel*.img mnt/boot/kernelA/
                cp mnt/boot/kernel*.img mnt/boot/kernelB/
                KERNEL_FILES_FOUND=1
                echo "✅ Converted vmlinuz files to kernel.img format"
            fi
        fi
    fi
fi

# If still no kernels found, try to download a minimal kernel
if [ "$KERNEL_FILES_FOUND" -eq 0 ]; then
    echo "⚠️  No kernels found - attempting to download minimal Raspbian kernel..."
    
    # Download a single kernel file for emergency boot
    EMERGENCY_KERNEL_URL="https://github.com/raspberrypi/firmware/raw/master/boot/kernel8.img"
    
    if wget -q "$EMERGENCY_KERNEL_URL" -O mnt/boot/kernel8.img; then
        echo "📥 Downloaded emergency kernel8.img"
        
        # Create basic kernel set
        cp mnt/boot/kernel8.img mnt/boot/kernel.img
        cp mnt/boot/kernel8.img mnt/boot/kernel7.img
        cp mnt/boot/kernel8.img mnt/boot/kernel7l.img
        
        # Copy to A/B directories
        cp mnt/boot/kernel*.img mnt/boot/kernelA/
        cp mnt/boot/kernel*.img mnt/boot/kernelB/
        
        KERNEL_FILES_FOUND=1
        echo "✅ Emergency kernel setup complete"
        echo "⚠️  WARNING: Using emergency kernel - modules may not match"
    else
        echo "❌ Failed to download emergency kernel"
    fi
fi

if [ "$KERNEL_FILES_FOUND" -eq 0 ]; then
    echo "❌ FATAL: No kernel files found and unable to download emergency kernel"
    echo "🔍 Debug info:"
    echo "   • Rootfs path: $ROOTFS_PATH"
    echo "   • Kernel files path: $KERNEL_FILES_PATH"
    echo "   • Boot contents: $(ls mnt/boot/ | tr '\n' ' ')"
    exit 1
fi

# =====================================================
# CREATE MINIMAL SAFE CONFIG.TXT WITH Pi Zero 2W OPTIMIZATIONS
# =====================================================

echo "⚙️ Creating minimal config.txt with Pi Zero 2W WiFi stability..."

cat > mnt/boot/config.txt << 'EOF'
# Pi-Star Alpine+Raspbian Hybrid Config
# Minimal settings for reliable boot + Pi Zero 2W WiFi stability

# Essential GPIO/SPI/I2C for Pi-Star
dtparam=spi=on
dtparam=i2c_arm=on

# Disable audio globally for better WiFi stability and resource savings
dtparam=audio=off

# Safe video driver (proven stable)
dtoverlay=vc4-fkms-v3d

# Conservative settings
disable_overscan=1
gpu_mem=64

# Model-specific kernels and Pi Zero 2W WiFi fixes
[pi1]
kernel=kernel.img

[pi2]
kernel=kernel7.img

[pi3]
kernel=kernel8.img
arm_freq=1000
gpu_freq=100

[pi3+]
kernel=kernel8.img
arm_freq=1200
gpu_freq=100

[pi02]
# Pi Zero 2W specific settings for WiFi stability
cmdline=cmdline02w.txt
kernel=kernel8.img
arm_freq=900
gpu_freq=100
# Critical WiFi stability settings for Pi Zero 2W
dtparam=sd_poll_once=on

[pi4]
kernel=kernel7l.img

[pi5]
kernel=kernel_2712.img

[all]
# UART for Pi-Star
dtoverlay=miniuart-bt
dtparam=uart0=on
EOF

# =====================================================
# CREATE Pi Zero 2W SPECIFIC CMDLINE
# =====================================================

echo "📶 Creating Pi Zero 2W specific cmdline.txt..."

cat > mnt/boot/cmdline02w.txt << 'EOF'
dwc_otg.lpm_enable=0 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 elevator=deadline fsck.repair=yes fsck.mode=force brcmfmac.roamoff=1 brcmfmac.feature_disable=0x82000 net.ifnames=0 rootwait quiet noswap
EOF

# Create standard cmdline.txt
cat > mnt/boot/cmdline.txt << 'EOF'
dwc_otg.lpm_enable=0 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 elevator=deadline fsck.repair=yes fsck.mode=force net.ifnames=0 rootwait quiet noswap
EOF

# =====================================================
# CREATE A/B STATE FILE
# =====================================================

echo "A" > mnt/boot/ab_state
echo "✅ Set initial boot to partition A"

# =====================================================
# INSTALL ROOT FILESYSTEMS (A and B)
# =====================================================

echo "📦 Installing Alpine+Raspbian hybrid to partition A..."
if [ -d "$ROOTFS_PATH" ]; then
    # Copy the complete hybrid rootfs to partition A
    cp -a "$ROOTFS_PATH"/* mnt/root-a/
    
    # Create kernel directory structure in root partition A
    mkdir -p mnt/root-a/boot/kernelA
    if ls mnt/boot/kernel*.img >/dev/null 2>&1; then
        cp mnt/boot/kernel*.img mnt/root-a/boot/kernelA/
    fi
    
    echo "✅ Installed to partition A"
else
    echo "❌ Rootfs directory not found"
    exit 1
fi

echo "📦 Installing Alpine+Raspbian hybrid to partition B (identical copy)..."
cp -a mnt/root-a/* mnt/root-b/

# Update kernel directory for partition B
mkdir -p mnt/root-b/boot/kernelB
if ls mnt/boot/kernel*.img >/dev/null 2>&1; then
    cp mnt/boot/kernel*.img mnt/root-b/boot/kernelB/
fi

echo "✅ Installed to partition B"

# =====================================================
# SET UP PERSISTENT DATA DIRECTORY
# =====================================================

echo "💾 Setting up persistent data partition..."
mkdir -p mnt/data/{config,logs,database,backup}

# =====================================================
# CREATE FSTAB FOR BOTH PARTITIONS
# =====================================================

create_fstab() {
    local root_dir="$1"
    cat > "${root_dir}/etc/fstab" << 'EOF'
# Pi-Star A/B Partition Layout (Alpine+Raspbian hybrid)
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

# =====================================================
# SET VERSION INFORMATION
# =====================================================

echo "$VERSION" > mnt/root-a/etc/pi-star-version
echo "$VERSION" > mnt/root-b/etc/pi-star-version

# Add hybrid information
echo "Alpine+Raspbian hybrid kernel $KERNEL_VERSION" > mnt/root-a/etc/alpine-raspbian-hybrid
echo "Alpine+Raspbian hybrid kernel $KERNEL_VERSION" > mnt/root-b/etc/alpine-raspbian-hybrid

# =====================================================
# CREATE BOOT TROUBLESHOOTING GUIDE
# =====================================================

cat > mnt/boot/BOOT_TROUBLESHOOTING.txt << 'EOF'
# Pi-Star Alpine+Raspbian Hybrid Boot Troubleshooting

## SYSTEM ARCHITECTURE

This is a hybrid system combining:
- Alpine Linux userland (~50MB) - minimal, secure base
- Raspbian kernel + firmware (~60MB) - proven Pi hardware support
- Total system size: ~110MB (perfect for A/B updates)

## A/B PARTITION LAYOUT

/dev/mmcblk0p1 - Boot (128MB) - Shared firmware + A/B kernels
/dev/mmcblk0p2 - Root A (650MB) - Alpine+Raspbian system A
/dev/mmcblk0p3 - Root B (650MB) - Alpine+Raspbian system B  
/dev/mmcblk0p4 - Data (500MB) - Persistent Pi-Star data

## KERNEL MANAGEMENT

- Shared /boot contains active kernel + firmware
- Each root partition has its own kernel backup in /boot/kernelA/ or /boot/kernelB/
- Updates copy new kernel to shared /boot and switch root partition
- Rollback copies old kernel back from partition's backup directory

## Pi Zero 2W WIFI STABILITY

Special optimizations included:
- cmdline02w.txt with brcmfmac.roamoff=1 and feature_disable=0x82000
- Conservative CPU/GPU frequencies (900/100 MHz)
- SD card polling optimization (sd_poll_once=on)
- Audio disabled globally to free resources

## TROUBLESHOOTING

1. Boot failure: Check /boot/ab_state to see active partition
2. WiFi issues: Verify brcmfmac firmware in /lib/firmware/brcm/
3. Kernel mismatch: Check kernel version matches /lib/modules/
4. A/B rollback: Use partition-switcher script to switch partitions

## FIRST BOOT CONFIGURATION

Create /boot/pistar-config.txt with:
wifi_ssid=YourNetwork
wifi_password=YourPassword
user_password=YourSecurePassword
ssh_key=ssh-rsa AAAAB3... your-key

Repository: https://github.com/MW0MWZ/Pi-Star_Alpine_Rolling
EOF

# Create configuration example
cat > mnt/boot/pistar-config.txt.sample << 'EOF'
# Pi-Star Boot Configuration Example
# Rename to 'pistar-config.txt' and edit

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

# =====================================================
# CREATE HYBRID SYSTEM INFO
# =====================================================

cat > mnt/boot/HYBRID_INFO.txt << EOF
# Pi-Star Alpine+Raspbian Hybrid Information

Build Version: $VERSION
Build Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Architecture: Alpine Linux userland + Raspbian kernel hybrid

COMPONENTS:
- Alpine Linux ${ALPINE_VERSION:-3.22} userland (~50MB)
- Raspbian kernel $KERNEL_VERSION (~40MB)
- Minimal Pi firmware and device trees (~20MB)
- Total system size: ~110MB

BENEFITS:
- Ultra-minimal footprint (vs 1200MB full Raspbian)
- Proven Pi hardware support (all models, all overlays)
- Perfect for A/B updates (fits 650MB partitions easily)
- Pi Zero 2W WiFi stability optimizations included
- Secure Alpine base with Raspbian hardware compatibility

SUPPORTED PI MODELS:
- Pi Zero, Pi Zero W, Pi Zero 2W (with WiFi optimizations)
- Pi 2B, Pi 3B, Pi 3B+
- Pi 4B, Pi 5B
- All variants with complete hardware support

WiFi OPTIMIZATION:
- Pi Zero 2W specific cmdline.txt with stability fixes
- Conservative frequencies for electrical noise reduction
- Roaming disabled to prevent connection drops
- Power management features disabled for stability

For support: https://github.com/MW0MWZ/Pi-Star_Alpine_Rolling
EOF

# =====================================================
# UNMOUNT AND FINALIZE
# =====================================================

echo "🔓 Unmounting partitions..."
umount mnt/boot mnt/root-a mnt/root-b mnt/data

# Detach loop device
losetup -d "$LOOP_DEVICE"

# Compress the image
echo "🗜️ Compressing image..."
gzip "$OUTPUT_FILE"

echo ""
echo "🎉 ALPINE + RASPBIAN HYBRID SD IMAGE COMPLETE!"
echo "📁 Image: ${OUTPUT_FILE}.gz"
echo "📏 Uncompressed size: 2GB (fits 2GB SD cards)"
echo "📦 Compressed size: $(ls -lh "${OUTPUT_FILE}.gz" | awk '{print $5}')"
echo ""
echo "🏗️ HYBRID ARCHITECTURE:"
echo "  • Alpine userland: ~50MB (musl, busybox, OpenRC)"
echo "  • Raspbian kernel: ~60MB (proven Pi hardware support)"
echo "  • Total system: ~110MB (vs 1200MB full Raspbian)"
echo ""
echo "🔄 A/B PARTITION LAYOUT:"
echo "  • /dev/mmcblk0p1 - Boot (128MB) - Shared firmware + A/B kernels"
echo "  • /dev/mmcblk0p2 - Root A (650MB) - Alpine+Raspbian system A"  
echo "  • /dev/mmcblk0p3 - Root B (650MB) - Alpine+Raspbian system B"
echo "  • /dev/mmcblk0p4 - Data (500MB) - Persistent Pi-Star data"
echo ""
echo "📶 Pi Zero 2W WIFI OPTIMIZATIONS:"
echo "  ✅ Special cmdline02w.txt with stability fixes"
echo "  ✅ Conservative frequencies (900/100 MHz)"
echo "  ✅ SD polling optimization"
echo "  ✅ Audio disabled for resource savings"
echo ""
echo "✨ BENEFITS:"
echo "  ✅ Proven Raspbian hardware support"
echo "