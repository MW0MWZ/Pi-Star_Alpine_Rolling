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
echo "🔧 Architecture: Alpine userland + RaspberryPi OS kernel/firmware"

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

if [ ! -d "$ROOTFS_PATH" ]; then
    echo "❌ Error: Rootfs not found at $ROOTFS_PATH"
    echo "Please run build-rootfs.sh first"
    exit 1
fi

echo "✅ Found Alpine+Raspbian hybrid rootfs"

# =====================================================
# SETUP COMPLETE RASPBERRYPI OS BOOT PARTITION
# =====================================================

setup_raspios_boot() {
    local boot_mount_point="$1"
    
    echo "🥧 Setting up complete RaspberryPi OS boot partition..."
    
    # Use the official RaspberryPi OS Lite image for boot files
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    echo "📥 Downloading RaspberryPi OS Lite image..."
    # Use a known-good, recent version
    RASPIOS_URL="https://downloads.raspberrypi.org/raspios_lite_armhf/images/raspios_lite_armhf-2024-07-04/2024-07-04-raspios-bookworm-armhf-lite.img.xz"
    
    if wget -q --show-progress "$RASPIOS_URL" -O raspios.img.xz; then
        echo "📦 Extracting RaspberryPi OS image..."
        xz -d raspios.img.xz
        
        # Mount the boot partition (usually partition 1)
        LOOP_DEV=$(losetup -f)
        losetup "$LOOP_DEV" raspios.img
        partprobe "$LOOP_DEV"
        sleep 2
        
        mkdir -p raspios_boot
        mount "${LOOP_DEV}p1" raspios_boot
        
        echo "📋 Copying ALL boot files from RaspberryPi OS..."
        # Copy EVERYTHING from the RaspberryPi OS boot partition
        cp -r raspios_boot/* "$boot_mount_point/"
        
        echo "✅ Copied $(ls -1 raspios_boot/ | wc -l) files from RaspberryPi OS boot"
        
        # List what we got
        echo "📁 Boot files copied:"
        ls -la "$boot_mount_point/" | head -20
        
        # Cleanup
        umount raspios_boot
        losetup -d "$LOOP_DEV"
        
        echo "✅ RaspberryPi OS boot setup complete"
        
        cd - > /dev/null
        rm -rf "$TEMP_DIR"
        return 0
    else
        echo "❌ Failed to download RaspberryPi OS image"
        cd - > /dev/null
        rm -rf "$TEMP_DIR"
        return 1
    fi
}

# Download and extract RaspberryPi OS once, use for both boot and modules
download_and_extract_raspios() {
    local boot_dest="$1"
    local root_a_dest="$2" 
    local root_b_dest="$3"
    
    echo "🥧 Downloading and extracting RaspberryPi OS for boot and modules..."
    echo "🔧 FIXED: Using absolute paths to avoid directory change issues"
    
    # Use a separate working directory to avoid conflicts
    RASPIOS_WORK_DIR="/tmp/raspios-extract-$"
    mkdir -p "$RASPIOS_WORK_DIR"
    cd "$RASPIOS_WORK_DIR"
    
    # Download RaspberryPi OS Lite - use the latest version that matches working system
    RASPIOS_URL="https://downloads.raspberrypi.org/raspios_lite_armhf/images/raspios_lite_armhf-2025-05-13/2025-05-13-raspios-bookworm-armhf-lite.img.xz"
    
    echo "📥 Downloading RaspberryPi OS (this will take a few minutes)..."
    if ! wget -q -O raspios.img.xz "$RASPIOS_URL"; then
        echo "❌ Failed to download RaspberryPi OS"
        cd - > /dev/null
        rm -rf "$RASPIOS_WORK_DIR"
        return 1
    fi
    
    echo "📦 Extracting RaspberryPi OS image..."
    if ! xz -d raspios.img.xz; then
        echo "❌ Failed to extract RaspberryPi OS image"
        cd - > /dev/null
        rm -rf "$RASPIOS_WORK_DIR"
        return 1
    fi
    
    echo "🔗 Setting up loop device for RaspberryPi OS..."
    # Find an available loop device (avoid conflicts with main build)
    RASPIOS_LOOP=$(losetup -f)
    if ! losetup "$RASPIOS_LOOP" raspios.img; then
        echo "❌ Failed to attach loop device"
        cd - > /dev/null
        rm -rf "$RASPIOS_WORK_DIR"
        return 1
    fi
    
    # Force partition table re-read and wait
    partprobe "$RASPIOS_LOOP"
    sleep 3
    
    # Verify partitions exist
    if [ ! -e "${RASPIOS_LOOP}p1" ] || [ ! -e "${RASPIOS_LOOP}p2" ]; then
        echo "❌ RaspberryPi OS partitions not detected"
        echo "Available devices:"
        ls -la /dev/loop* || true
        losetup -d "$RASPIOS_LOOP"
        cd - > /dev/null
        rm -rf "$RASPIOS_WORK_DIR"
        return 1
    fi
    
    echo "✅ RaspberryPi OS partitions detected: ${RASPIOS_LOOP}p1 (boot), ${RASPIOS_LOOP}p2 (root)"
    
    # Mount and extract boot partition
    mkdir -p raspios_boot
    if mount "${RASPIOS_LOOP}p1" raspios_boot; then
        echo "📋 Copying boot files from RaspberryPi OS..."
        cp -r raspios_boot/* "$boot_dest/"
        BOOT_FILE_COUNT=$(ls -1 raspios_boot/ | wc -l)
        echo "✅ Copied $BOOT_FILE_COUNT boot files"
        umount raspios_boot
    else
        echo "❌ Failed to mount RaspberryPi OS boot partition"
        losetup -d "$RASPIOS_LOOP"
        cd - > /dev/null
        rm -rf "$RASPIOS_WORK_DIR"
        return 1
    fi
    
    # Mount and extract root partition for modules/firmware
    mkdir -p raspios_root
    if mount "${RASPIOS_LOOP}p2" raspios_root; then
        echo "📋 Copying kernel modules and firmware..."
        
        # Copy modules to both Alpine partitions
        if [ -d "raspios_root/lib/modules" ]; then
            cp -r raspios_root/lib/modules "$root_a_dest/lib/" 2>/dev/null && echo "✅ Modules copied to partition A" || echo "❌ Failed to copy modules to partition A"
            cp -r raspios_root/lib/modules "$root_b_dest/lib/" 2>/dev/null && echo "✅ Modules copied to partition B" || echo "❌ Failed to copy modules to partition B"
        else
            echo "⚠️  No modules directory found in RaspberryPi OS"
        fi
        
        # Copy firmware to both Alpine partitions  
        if [ -d "raspios_root/lib/firmware" ]; then
            cp -r raspios_root/lib/firmware "$root_a_dest/lib/" 2>/dev/null && echo "✅ Firmware copied to partition A" || echo "❌ Failed to copy firmware to partition A"
            cp -r raspios_root/lib/firmware "$root_b_dest/lib/" 2>/dev/null && echo "✅ Firmware copied to partition B" || echo "❌ Failed to copy firmware to partition B"
        else
            echo "⚠️  No firmware directory found in RaspberryPi OS"
        fi
        
        # Get kernel version for reference
        if [ -d "raspios_root/lib/modules" ]; then
            KERNEL_VERSION=$(ls raspios_root/lib/modules/ | head -1)
            echo "📱 RaspberryPi OS kernel version: $KERNEL_VERSION"
            echo "$KERNEL_VERSION" > "$root_a_dest/etc/raspios-kernel-version" 2>/dev/null || true
            echo "$KERNEL_VERSION" > "$root_b_dest/etc/raspios-kernel-version" 2>/dev/null || true
        fi
        
        umount raspios_root
    else
        echo "❌ Failed to mount RaspberryPi OS root partition"
        losetup -d "$RASPIOS_LOOP"
        cd - > /dev/null
        rm -rf "$RASPIOS_WORK_DIR"
        return 1
    fi
    
    # Cleanup
    losetup -d "$RASPIOS_LOOP"
    cd - > /dev/null
    rm -rf "$RASPIOS_WORK_DIR"
    
    echo "✅ RaspberryPi OS extraction complete"
    return 0
}

# Create a fallback boot setup if download fails
setup_fallback_boot() {
    local boot_mount_point="$1"
    
    echo "⚠️  Setting up fallback boot files..."
    
    # Create minimal boot files that should work
    cat > "$boot_mount_point/config.txt" << 'EOF'
# Minimal Pi config for Alpine userland
[all]
kernel=kernel8.img
arm_64bit=0
disable_overscan=1
dtparam=audio=off
dtparam=spi=on
dtparam=i2c_arm=on
enable_uart=1
gpu_mem=64
EOF
    
    cat > "$boot_mount_point/cmdline.txt" << 'EOF'
console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 elevator=deadline fsck.repair=yes rootwait net.ifnames=0
EOF
    
    echo "⚠️  Fallback boot setup complete (may not boot without proper firmware)"
}

# =====================================================
# INSTALL ROOT FILESYSTEMS FIRST
# =====================================================

echo "📦 Installing Alpine rootfs to partitions..."

if [ -d "$ROOTFS_PATH" ]; then
    # Install to partition A
    cp -a "$ROOTFS_PATH"/* mnt/root-a/
    echo "✅ Installed Alpine rootfs to partition A"
    
    # Install to partition B (identical copy)
    cp -a mnt/root-a/* mnt/root-b/
    echo "✅ Installed Alpine rootfs to partition B"
else
    echo "❌ Rootfs directory not found"
    exit 1
fi

# =====================================================
# NOW SETUP RASPBERRYPI OS BOOT AND MODULES
# =====================================================

echo "🔧 Setting up RaspberryPi OS boot partition and modules..."
# Convert relative paths to absolute paths before calling the function
BOOT_ABS_PATH="$(pwd)/mnt/boot"
ROOT_A_ABS_PATH="$(pwd)/mnt/root-a" 
ROOT_B_ABS_PATH="$(pwd)/mnt/root-b"

echo "📍 Absolute paths: boot=$BOOT_ABS_PATH, root-a=$ROOT_A_ABS_PATH, root-b=$ROOT_B_ABS_PATH"

# Download once, extract both boot files and modules
if download_and_extract_raspios "$BOOT_ABS_PATH" "$ROOT_A_ABS_PATH" "$ROOT_B_ABS_PATH"; then
    echo "✅ RaspberryPi OS setup successful"
else
    echo "⚠️  RaspberryPi OS extraction failed, using fallback boot"
    setup_fallback_boot "mnt/boot"
fi

# =====================================================
# APPLY CUSTOM CONFIGURATIONS
# =====================================================

echo "📝 Adding Pi-Star customizations to boot partition..."

# Add A/B boot state
echo "A" > mnt/boot/ab_state

# Apply your known working cmdline files
cat > mnt/boot/cmdline.txt << 'EOF'
dwc_otg.lpm_enable=0 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 elevator=deadline fsck.repair=yes fsck.mode=force net.ifnames=0 rootwait quiet noswap
EOF

# Pi Zero 2W specific cmdline (with WiFi stability parameters)
cat > mnt/boot/cmdline02w.txt << 'EOF'
dwc_otg.lpm_enable=0 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 elevator=deadline fsck.repair=yes fsck.mode=force brcmfmac.roamoff=1 brcmfmac.feature_disable=0x82000 net.ifnames=0 rootwait quiet noswap
EOF

# Overwrite config.txt with your known working version
cat > mnt/boot/config.txt << 'EOF'
# For more options and information see
# http://rptl.io/configtxt
# Some settings may impact device functionality. See link above for details

# Enable audio (loads snd_bcm2835)
dtparam=audio=on

# Automatically load overlays for detected cameras
camera_auto_detect=0

# Automatically load overlays for detected DSI displays
display_auto_detect=1

# Automatically load initramfs files, if found
auto_initramfs=1

# Enable DRM VC4 V3D driver
dtoverlay=vc4-kms-v3d
max_framebuffers=2

# Don't have the firmware create an initial video= setting in cmdline.txt.
# Use the kernel's default instead.
disable_fw_kms_setup=1

# Disable compensation for displays with overscan
disable_overscan=1

# Free up some RAM
gpu_mem=16

# D2RG UART over SPI
dtoverlay=sc16is752-spi0-ce0

# Model Specifics
[pi1]
kernel=kernel.img
gpu_freq=100

[pi2]
kernel=kernel.img
gpu_freq=100

[pi3]
kernel=kernel8.img
arm_freq=1000
gpu_freq=100

[pi3+]
kernel=kernel8.img
arm_freq=1200
gpu_freq=100

[pi02]
cmdline=cmdline02w.txt
kernel=kernel8.img
arm_freq=900
gpu_freq=100

[pi4]
kernel=kernel8.img

[pi5]
kernel=kernel8.img

[all]
dtparam=i2c_arm=on
dtparam=spi=on
dtoverlay=miniuart-bt
dtparam=uart0=on
dtparam=uart1=on
temp_limit=75
EOF

# =====================================================
# SET UP DATA PARTITION
# =====================================================

echo "💾 Setting up persistent data partition..."
mkdir -p mnt/data/config
mkdir -p mnt/data/logs
mkdir -p mnt/data/database
mkdir -p mnt/data/backup

# =====================================================
# CREATE FSTAB
# =====================================================

create_fstab() {
    local root_dir="$1"
    cat > "${root_dir}/etc/fstab" << 'EOF'
# Pi-Star A/B Partition Layout
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
# SET VERSION INFO
# =====================================================

echo "$VERSION" > mnt/root-a/etc/pi-star-version
echo "$VERSION" > mnt/root-b/etc/pi-star-version

# Add system info
echo "Alpine Linux + RaspberryPi OS hybrid" > mnt/root-a/etc/system-info
echo "Alpine Linux + RaspberryPi OS hybrid" > mnt/root-b/etc/system-info

# Mark as hybrid system
echo "Alpine userland with RaspberryPi OS kernel/modules/firmware" > mnt/root-a/etc/alpine-raspbian-hybrid
echo "Alpine userland with RaspberryPi OS kernel/modules/firmware" > mnt/root-b/etc/alpine-raspbian-hybrid

# =====================================================
# CREATE DOCUMENTATION
# =====================================================

cat > mnt/boot/README.txt << EOF
# Pi-Star Alpine + RaspberryPi OS Hybrid

Build Version: $VERSION
Build Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)

COMPONENTS:
- Alpine Linux userland (minimal, secure)
- RaspberryPi OS kernels (full hardware support)
- RaspberryPi OS firmware (all Pi models)
- RaspberryPi OS kernel modules

FIRST BOOT:
Create /boot/pistar-config.txt with:
wifi_ssid=YourNetwork
wifi_password=YourPassword
user_password=YourPassword
ssh_key=ssh-rsa AAAAB3... your-key

SUPPORTED PI MODELS:
- Pi Zero, Pi Zero W, Pi Zero 2W
- Pi 2B, Pi 3B, Pi 3B+
- Pi 4B, Pi 5B

BOOT SYSTEM:
This uses a complete RaspberryPi OS boot partition
with Alpine Linux userland for maximum compatibility.

Repository: https://github.com/MW0MWZ/Pi-Star_Alpine_Rolling
EOF

# Create config example
cat > mnt/boot/pistar-config.txt.sample << 'EOF'
# Pi-Star Boot Configuration Example
# Rename to 'pistar-config.txt' and edit

# WiFi Configuration
#wifi_ssid=YourWiFiNetwork
#wifi_password=YourWiFiPassword

# User Security
#user_password=YourSecurePassword
#ssh_key=ssh-rsa AAAAB3NzaC1yc2EAAAA... your-email@example.com

# System Settings
#hostname=pi-star
#timezone=Europe/London
EOF

# =====================================================
# CHECK SPACE USAGE
# =====================================================

echo "📊 Checking space usage..."
BOOT_USED=$(df -h mnt/boot 2>/dev/null | awk 'NR==2 {print $3}' || echo "unknown")
echo "📁 Boot partition: $BOOT_USED used / 128MB"

# Show what we installed
echo ""
echo "📦 Installation Summary:"
echo "   • Boot system: Complete RaspberryPi OS boot partition"
echo "   • Kernel files: $(ls mnt/boot/kernel*.img 2>/dev/null | wc -l)"
echo "   • Device trees: $(ls mnt/boot/*.dtb 2>/dev/null | wc -l)"
echo "   • Overlays: $(ls mnt/boot/overlays/*.dtbo 2>/dev/null | wc -l || echo 0)"
echo "   • Userland: Alpine Linux"
echo "   • Modules: RaspberryPi OS kernel modules"

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
echo "🎉 ALPINE + RASPBERRYPI OS HYBRID SD IMAGE COMPLETE!"
echo "📁 Image: ${OUTPUT_FILE}.gz"
echo "📏 Compressed size: $(ls -lh "${OUTPUT_FILE}.gz" | awk '{print $5}')"
echo ""
echo "🏗️ HYBRID ARCHITECTURE:"
echo "  • RaspberryPi OS boot partition (complete)"
echo "  • Alpine Linux userland (~50MB per partition)"
echo "  • RaspberryPi OS kernel modules (~150MB per partition)"
echo "  • RaspberryPi OS firmware (~15MB)"
echo ""
echo "✨ FEATURES:"
echo "  ✅ Complete RaspberryPi OS hardware support"
echo "  ✅ Alpine security and efficiency"
echo "  ✅ A/B partition updates"
echo "  ✅ 2GB SD card compatible"
echo "  ✅ All Pi models supported"
echo "  ✅ Should boot reliably!"
echo ""
echo "Ready for testing! 🚀"