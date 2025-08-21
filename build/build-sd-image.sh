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

# Create enhanced first-boot setup script
cat > mnt/root-a/usr/local/bin/first-boot-setup << 'EOF'
#!/bin/bash
# Enhanced first boot setup for Pi-Star A/B system

echo "Pi-Star First Boot Setup"
echo "======================="

# CRITICAL: Check if boot configuration was processed FIRST
if [ -f "/boot/.config-processed" ]; then
    echo "✅ Boot configuration found and processed from /boot/pistar-config.txt"
    echo "   User account and system settings configured automatically"
    echo "   Skipping manual setup prompts"
    
    # Show what was configured
    if [ -f "/boot/pistar-config.txt" ]; then
        echo ""
        echo "Configuration applied from boot partition:"
        
        # Check if WiFi was configured
        if grep -q "^wifi_ssid" /boot/pistar-config.txt 2>/dev/null; then
            WIFI_SSID=$(grep "^wifi_ssid" /boot/pistar-config.txt | head -1 | cut -d'=' -f2)
            echo "• WiFi: Configured for '$WIFI_SSID' (and additional networks)"
        fi
        
        # Check if user password was set
        if grep -q "^user_password" /boot/pistar-config.txt 2>/dev/null; then
            echo "• User: Password set for pi-star user"
        fi
        
        # Check if SSH key was configured
        if grep -q "^ssh_key" /boot/pistar-config.txt 2>/dev/null; then
            echo "• SSH: Public key authentication configured"
        fi
        
        # Check hostname
        if grep -q "^hostname" /boot/pistar-config.txt 2>/dev/null; then
            CONFIGURED_HOSTNAME=$(grep "^hostname" /boot/pistar-config.txt | cut -d'=' -f2)
            echo "• Hostname: Set to '$CONFIGURED_HOSTNAME'"
        fi
    fi
    
    echo ""
    echo "✅ No manual configuration required"
    
else
    echo "ℹ️  No boot configuration found at /boot/pistar-config.txt"
    echo "   Manual setup required"
    
    # Check if running interactively (and stdin is available)
    if [ -t 0 ] && [ -t 1 ]; then
        echo ""
        echo "SECURITY NOTICE:"
        echo "================"
        echo "• Root account: DISABLED (no password, no SSH access)"
        echo "• pi-star user: Passwordless sudo enabled"
        echo "• SSH: Key authentication only (password auth disabled)"
        echo ""
        echo "⚠️  You MUST set a password for pi-star user OR configure SSH keys"
        echo "   to access this system remotely."
        echo ""
        
        # Give user a moment to read
        sleep 2
        
        # Offer to change pi-star password
        echo "Would you like to set a password for the pi-star user?"
        read -p "Set password? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Setting password for pi-star user..."
            passwd pi-star
            
            # Ask about SSH password authentication
            echo ""
            read -p "Enable SSH password authentication? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo "Enabling SSH password authentication..."
                sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
                sed -i 's/#PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
                
                # Restart SSH service
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl restart sshd
                else
                    service sshd restart
                fi
                echo "✅ SSH password authentication enabled"
            fi
        else
            echo ""
            echo "⚠️  WARNING: No password set for pi-star user!"
            echo ""
            echo "To access this system, you must:"
            echo "1. Connect via console/keyboard, or"
            echo "2. Configure SSH keys by creating /boot/pistar-config.txt with:"
            echo "   ssh_key=ssh-rsa AAAAB3NzaC1yc2EAAAA... your-email@example.com"
            echo ""
        fi
        
        # Network configuration help
        echo ""
        echo "NETWORK CONFIGURATION:"
        echo "====================="
        echo "To configure WiFi, create /boot/pistar-config.txt with:"
        echo "  wifi_ssid=YourNetworkName"
        echo "  wifi_password=YourPassword"
        echo ""
        if command -v iwconfig >/dev/null 2>&1; then
            echo "WiFi interface detected and available"
        fi
        if ip link show eth0 >/dev/null 2>&1; then
            echo "Ethernet interface available (DHCP auto-configured)"
        fi
        
        echo ""
        echo "For complete configuration options, see:"
        echo "https://github.com/MW0MWZ/Pi-Star_Alpine_Rolling#boot-configuration"
        
    else
        echo ""
        echo "Running non-interactively - no password prompts shown"
        echo ""
        echo "To configure this system:"
        echo "1. Create /boot/pistar-config.txt with your settings"
        echo "2. Reboot to apply configuration automatically"
        echo "3. Or connect via console and run 'sudo passwd pi-star'"
    fi
fi

# Validate system boot (A/B partition system)
if [ -f "/usr/local/bin/boot-validator" ]; then
    echo ""
    echo "Validating system boot..."
    /usr/local/bin/boot-validator
fi

# Mark first boot as complete
mkdir -p /opt/pistar
touch /opt/pistar/.first-boot-complete

echo ""
echo "Pi-Star A/B system first boot complete"
echo "======================================"

# Show system status
echo ""
echo "SYSTEM STATUS:"
echo "• Hostname: $(hostname)"
echo "• Active partition: $(cat /boot/ab_state 2>/dev/null || echo 'Unknown')"
echo "• Pi-Star version: $(cat /etc/pi-star-version 2>/dev/null || echo 'Unknown')"

# Show network status
if command -v ip >/dev/null 2>&1; then
    echo "• Network interfaces:"
    ip addr show | grep "inet " | grep -v "127.0.0.1" | while read line; do
        echo "  $line"
    done
fi

# Show SSH access information
echo "• SSH access:"
if [ -f "/etc/ssh/sshd_config" ]; then
    if grep -q "PasswordAuthentication yes" /etc/ssh/sshd_config; then
        echo "  Password authentication: ENABLED"
    else
        echo "  Password authentication: DISABLED (key-only)"
    fi
fi

if [ -f "/home/pi-star/.ssh/authorized_keys" ] && [ -s "/home/pi-star/.ssh/authorized_keys" ]; then
    echo "  SSH keys: Configured"
else
    echo "  SSH keys: Not configured"
fi

echo ""
echo "For support and documentation:"
echo "• Repository: https://github.com/MW0MWZ/Pi-Star_Alpine_Rolling"
echo "• Update server: https://version.pistar.uk"
echo "• Boot config: Create /boot/pistar-config.txt for automated setup"
EOF

chmod +x mnt/root-a/usr/local/bin/first-boot-setup
cp mnt/root-a/usr/local/bin/first-boot-setup mnt/root-b/usr/local/bin/first-boot-setup

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
echo "Uncompressed size: 2GB (fits 2GB SD cards)"
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
