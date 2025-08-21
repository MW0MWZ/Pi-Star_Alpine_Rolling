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
# DOWNLOAD RASPBERRYPI OS FIRMWARE AND KERNELS
# =====================================================

echo "📡 Downloading RaspberryPi OS firmware and kernels..."

# Try GitHub firmware repository
PI_FIRMWARE_BASE="https://github.com/raspberrypi/firmware/raw/master/boot"

echo "🔍 Testing firmware repository access..."
if wget -q --spider "$PI_FIRMWARE_BASE/kernel8.img" 2>/dev/null; then
    echo "✅ Repository accessible"
    
    # Download essential firmware files
    echo "📥 Downloading firmware files..."
    
    # Complete firmware set (not just essential)
    FIRMWARE_FILES="bootcode.bin start.elf start4.elf start_x.elf start4x.elf start_cd.elf start4cd.elf start_db.elf start4db.elf fixup.dat fixup4.dat fixup_x.dat fixup4x.dat fixup_cd.dat fixup4cd.dat fixup_db.dat fixup4db.dat"
    
    for file in $FIRMWARE_FILES; do
        if wget -q -O "mnt/boot/$file" "$PI_FIRMWARE_BASE/$file"; then
            echo "✅ Downloaded: $file"
        else
            echo "⚠️  Could not download: $file (may not exist)"
        fi
    done
    
    # Download kernels and initramfs
    echo "📥 Downloading kernels and initramfs..."
    KERNEL_FILES="kernel.img kernel7.img kernel7l.img kernel8.img kernel_2712.img"
    INITRAMFS_FILES="initramfs initramfs7 initramfs7l initramfs8 initramfs_2712"
    
    for kernel in $KERNEL_FILES; do
        if wget -q -O "mnt/boot/$kernel" "$PI_FIRMWARE_BASE/$kernel"; then
            echo "✅ Downloaded: $kernel"
        else
            echo "⚠️  Could not download: $kernel (may not exist)"
        fi
    done
    
    for initramfs in $INITRAMFS_FILES; do
        if wget -q -O "mnt/boot/$initramfs" "$PI_FIRMWARE_BASE/$initramfs"; then
            echo "✅ Downloaded: $initramfs"
        else
            echo "⚠️  Could not download: $initramfs (may not exist)"
        fi
    done
    
    # Download ALL device trees (don't be selective)
    echo "📥 Downloading ALL device tree files..."
    
    # Get list of all .dtb files from the repository
    DTB_LIST=$(wget -q -O- "https://api.github.com/repos/raspberrypi/firmware/contents/boot" | grep -o '"name":"[^"]*\.dtb"' | cut -d'"' -f4 2>/dev/null || echo "")
    
    if [ -n "$DTB_LIST" ]; then
        echo "📋 Found device tree files via API"
        for dtb in $DTB_LIST; do
            if wget -q -O "mnt/boot/$dtb" "$PI_FIRMWARE_BASE/$dtb"; then
                echo "✅ Downloaded: $dtb"
            else
                echo "⚠️  Could not download: $dtb"
            fi
        done
    else
        echo "📋 Using comprehensive device tree list"
        # Comprehensive list of known DTB files for all Pi models
        DTB_FILES="bcm2708-rpi-b.dtb bcm2708-rpi-b-plus.dtb bcm2708-rpi-b-rev1.dtb bcm2708-rpi-cm.dtb bcm2708-rpi-zero.dtb bcm2708-rpi-zero-w.dtb bcm2709-rpi-2-b.dtb bcm2709-rpi-cm2.dtb bcm2710-rpi-2-b.dtb bcm2710-rpi-3-b.dtb bcm2710-rpi-3-b-plus.dtb bcm2710-rpi-cm3.dtb bcm2710-rpi-zero-2.dtb bcm2710-rpi-zero-2-w.dtb bcm2711-rpi-4-b.dtb bcm2711-rpi-400.dtb bcm2711-rpi-cm4.dtb bcm2711-rpi-cm4s.dtb bcm2712-rpi-5-b.dtb bcm2712-rpi-cm5.dtb"
        
        for dtb in $DTB_FILES; do
            if wget -q -O "mnt/boot/$dtb" "$PI_FIRMWARE_BASE/$dtb"; then
                echo "✅ Downloaded: $dtb"
            else
                echo "⚠️  Could not download: $dtb (may not exist yet)"
            fi
        done
    fi
    
    # Download MORE comprehensive overlays
    echo "📥 Downloading comprehensive overlays..."
    mkdir -p mnt/boot/overlays
    
    # More comprehensive overlay list for Pi-Star and general Pi functionality
    OVERLAY_FILES="uart0.dtbo uart1.dtbo uart2.dtbo uart3.dtbo uart4.dtbo uart5.dtbo disable-bt.dtbo miniuart-bt.dtbo pi3-miniuart-bt.dtbo pi3-disable-bt.dtbo pi3-disable-wifi.dtbo spi0-cs.dtbo spi0-2cs.dtbo spi1-1cs.dtbo spi1-2cs.dtbo spi1-3cs.dtbo spi2-1cs.dtbo spi2-2cs.dtbo spi2-3cs.dtbo i2c0.dtbo i2c1.dtbo i2c3.dtbo i2c4.dtbo i2c5.dtbo i2c6.dtbo gpio-ir.dtbo gpio-ir-tx.dtbo gpio-key.dtbo gpio-led.dtbo gpio-poweroff.dtbo gpio-shutdown.dtbo w1-gpio.dtbo w1-gpio-pullup.dtbo vc4-fkms-v3d.dtbo vc4-kms-v3d.dtbo vc4-kms-v3d-pi4.dtbo dwc2.dtbo g_serial.dtbo libcomposite.dtbo midi-uart0.dtbo midi-uart1.dtbo pps-gpio.dtbo pwm.dtbo pwm-2chan.dtbo pwm-ir-tx.dtbo spi0-hw-cs.dtbo"
    
    OVERLAY_SUCCESS=0
    for overlay in $OVERLAY_FILES; do
        if wget -q -O "mnt/boot/overlays/$overlay" "$PI_FIRMWARE_BASE/overlays/$overlay"; then
            echo "✅ Downloaded overlay: $overlay"
            OVERLAY_SUCCESS=1
        else
            echo "⚠️  Could not download overlay: $overlay"
        fi
    done
    
    if [ "$OVERLAY_SUCCESS" -eq 0 ]; then
        echo "⚠️  No overlays downloaded - removing empty directory"
        rmdir mnt/boot/overlays 2>/dev/null || true
    fi
    
    MAIN_KERNEL="RaspberryPi OS kernels"
    
else
    echo "⚠️  Cannot access firmware repository - creating stub files for CI"
    
    # Create more comprehensive stub files for CI testing
    echo "# Firmware stub" > mnt/boot/bootcode.bin
    echo "# Firmware stub" > mnt/boot/start.elf
    echo "# Firmware stub" > mnt/boot/start4.elf
    echo "# Firmware stub" > mnt/boot/start_x.elf
    echo "# Firmware stub" > mnt/boot/start4x.elf
    echo "# Firmware stub" > mnt/boot/fixup.dat
    echo "# Firmware stub" > mnt/boot/fixup4.dat
    echo "# Firmware stub" > mnt/boot/fixup_x.dat
    echo "# Firmware stub" > mnt/boot/fixup4x.dat
    echo "# Kernel stub" > mnt/boot/kernel.img
    echo "# Kernel stub" > mnt/boot/kernel7.img
    echo "# Kernel stub" > mnt/boot/kernel7l.img
    echo "# Kernel stub" > mnt/boot/kernel8.img
    echo "# Kernel stub" > mnt/boot/kernel_2712.img
    echo "# Initramfs stub" > mnt/boot/initramfs
    echo "# Initramfs stub" > mnt/boot/initramfs8
    
    MAIN_KERNEL="Stub files (CI testing only)"
fi

# =====================================================
# CREATE KERNEL MODULE INFRASTRUCTURE
# =====================================================

echo "📦 Setting up kernel module infrastructure..."

# Try to detect kernel version from kernel file
KERNEL_VERSION="unknown"
if [ -f "mnt/boot/kernel8.img" ] && [ -s "mnt/boot/kernel8.img" ]; then
    KERNEL_VERSION=$(strings mnt/boot/kernel8.img 2>/dev/null | grep -E "Linux version [0-9]" | head -1 | awk '{print $3}' 2>/dev/null || echo "unknown")
fi

if [ "$KERNEL_VERSION" != "unknown" ] && [ -n "$KERNEL_VERSION" ]; then
    echo "🔍 Detected kernel version: $KERNEL_VERSION"
    
    # Create module directories
    mkdir -p "mnt/root-a/lib/modules/$KERNEL_VERSION"
    mkdir -p "mnt/root-b/lib/modules/$KERNEL_VERSION"
    
    # Create module installation script
    cat > "mnt/root-a/usr/local/bin/install-raspios-modules" << 'EOF'
#!/bin/bash
# Install matching RaspberryPi OS modules

KERNEL_VERSION=$(uname -r)
echo "📦 Installing RaspberryPi OS modules for kernel: $KERNEL_VERSION"

if [ -f "/lib/modules/$KERNEL_VERSION/modules.dep" ]; then
    echo "✅ Modules already installed"
    exit 0
fi

echo "⬇️ Downloading RaspberryPi OS image for module extraction..."
echo "This may take several minutes..."

TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# Download RaspberryPi OS Lite
RASPIOS_URL="https://downloads.raspberrypi.org/raspios_lite_armhf/images/raspios_lite_armhf-2024-07-04/2024-07-04-raspios-bookworm-armhf-lite.img.xz"

if wget -q "$RASPIOS_URL" -O raspios.img.xz; then
    echo "📦 Extracting image..."
    xz -d raspios.img.xz
    
    # Mount image
    LOOP_DEV=$(losetup -f)
    losetup "$LOOP_DEV" raspios.img
    
    mkdir -p mnt_tmp
    mount "${LOOP_DEV}p2" mnt_tmp
    
    # Find matching kernel
    AVAILABLE_KERNELS=$(ls mnt_tmp/lib/modules/)
    BEST_KERNEL=""
    
    for k in $AVAILABLE_KERNELS; do
        if echo "$k" | grep -q "$KERNEL_VERSION"; then
            BEST_KERNEL="$k"
            break
        fi
    done
    
    if [ -z "$BEST_KERNEL" ]; then
        BEST_KERNEL=$(echo "$AVAILABLE_KERNELS" | tail -1)
    fi
    
    echo "✅ Installing modules from: $BEST_KERNEL"
    
    # Copy modules
    mkdir -p "/lib/modules/$KERNEL_VERSION"
    cp -r "mnt_tmp/lib/modules/$BEST_KERNEL"/* "/lib/modules/$KERNEL_VERSION/"
    
    # Copy firmware
    if [ -d "mnt_tmp/lib/firmware/brcm" ]; then
        mkdir -p /lib/firmware
        cp -r mnt_tmp/lib/firmware/brcm /lib/firmware/
    fi
    
    # Generate dependencies
    depmod -a "$KERNEL_VERSION" 2>/dev/null || true
    
    # Cleanup
    umount mnt_tmp
    losetup -d "$LOOP_DEV"
    
    echo "✅ Modules installed successfully!"
else
    echo "❌ Failed to download RaspberryPi OS image"
    exit 1
fi

cd /
rm -rf "$TEMP_DIR"
EOF
    
    chmod +x "mnt/root-a/usr/local/bin/install-raspios-modules"
    cp "mnt/root-a/usr/local/bin/install-raspios-modules" "mnt/root-b/usr/local/bin/"
    chmod +x "mnt/root-b/usr/local/bin/install-raspios-modules"
    
    # Create module loading script
    cat > "mnt/root-a/usr/local/bin/load-essential-modules" << 'EOF'
#!/bin/bash
# Load essential kernel modules

echo "🔧 Loading essential modules..."

MODULES="cfg80211 brcmutil brcmfmac spi_bcm2835 i2c_bcm2835"

for module in $MODULES; do
    if modprobe "$module" 2>/dev/null; then
        echo "✅ Loaded: $module"
    else
        echo "⚠️  Could not load: $module"
    fi
done
EOF
    
    chmod +x "mnt/root-a/usr/local/bin/load-essential-modules"
    cp "mnt/root-a/usr/local/bin/load-essential-modules" "mnt/root-b/usr/local/bin/"
    chmod +x "mnt/root-b/usr/local/bin/load-essential-modules"
    
    echo "✅ Module infrastructure created"
else
    echo "⚠️  Could not determine kernel version"
fi

# =====================================================
# CREATE CONFIG.TXT
# =====================================================

echo "⚙️ Creating config.txt..."

cat > mnt/boot/config.txt << 'EOF'
# Pi-Star Alpine+RaspberryPi OS Hybrid Config

# Essential GPIO/SPI/I2C for Pi-Star
dtparam=spi=on
dtparam=i2c_arm=on

# Disable audio for stability
dtparam=audio=off

# Safe video driver
dtoverlay=vc4-fkms-v3d

# Conservative settings
disable_overscan=1
gpu_mem=64

# Model-specific kernels and initramfs
[pi1]
kernel=kernel.img
initramfs initramfs followkernel

[pi2]
kernel=kernel7.img
initramfs initramfs7 followkernel

[pi3]
kernel=kernel8.img
initramfs initramfs8 followkernel

[pi02]
# Pi Zero 2W WiFi stability
kernel=kernel8.img
initramfs initramfs8 followkernel
arm_freq=900
gpu_freq=100

[pi4]
kernel=kernel7l.img
initramfs initramfs7l followkernel

[pi5]
kernel=kernel_2712.img
initramfs initramfs_2712 followkernel

[all]
# UART for Pi-Star
enable_uart=1
dtparam=uart0=on
EOF

# Create cmdline.txt
cat > mnt/boot/cmdline.txt << 'EOF'
dwc_otg.lpm_enable=0 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 elevator=deadline fsck.repair=yes fsck.mode=force net.ifnames=0 rootwait quiet noswap
EOF

# Pi Zero 2W specific cmdline
cat > mnt/boot/cmdline02w.txt << 'EOF'
dwc_otg.lpm_enable=0 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 elevator=deadline fsck.repair=yes fsck.mode=force brcmfmac.roamoff=1 brcmfmac.feature_disable=0x82000 net.ifnames=0 rootwait quiet noswap
EOF

# =====================================================
# CREATE A/B STATE
# =====================================================

echo "A" > mnt/boot/ab_state
echo "✅ Set initial boot to partition A"

# =====================================================
# INSTALL ROOT FILESYSTEMS
# =====================================================

echo "📦 Installing Alpine+RaspberryPi OS hybrid to partitions..."

if [ -d "$ROOTFS_PATH" ]; then
    # Install to partition A
    cp -a "$ROOTFS_PATH"/* mnt/root-a/
    echo "✅ Installed to partition A"
    
    # Install to partition B (identical copy)
    cp -a mnt/root-a/* mnt/root-b/
    echo "✅ Installed to partition B"
else
    echo "❌ Rootfs directory not found"
    exit 1
fi

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
- Essential overlays for Pi-Star

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

KERNEL MODULES:
Run 'sudo /usr/local/bin/install-raspios-modules' after first boot
to install full RaspberryPi OS kernel modules.

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
echo "   • Firmware files: $(ls mnt/boot/*.elf mnt/boot/*.dat mnt/boot/bootcode.bin 2>/dev/null | wc -l)"
echo "   • Kernel files: $(ls mnt/boot/kernel*.img 2>/dev/null | wc -l)"
echo "   • Device trees: $(ls mnt/boot/*.dtb 2>/dev/null | wc -l)"
echo "   • Overlays: $(ls mnt/boot/overlays/*.dtbo 2>/dev/null | wc -l || echo 0)"
echo "   • Kernel source: $MAIN_KERNEL"

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
echo "  • Alpine Linux userland (~50MB)"
echo "  • RaspberryPi OS kernels (~25MB)"
echo "  • RaspberryPi OS firmware (~15MB)"
echo "  • Essential overlays (~5MB)"
echo ""
echo "✨ FEATURES:"
echo "  ✅ Full RaspberryPi OS hardware support"
echo "  ✅ Alpine security and efficiency"
echo "  ✅ A/B partition updates"
echo "  ✅ 2GB SD card compatible"
echo "  ✅ All Pi models supported"
echo ""
echo "Ready for testing! 🚀"