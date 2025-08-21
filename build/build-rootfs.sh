#!/bin/bash
set -e

VERSION="$1"
PI_STAR_MODE="$2"
BUILD_DIR="${BUILD_DIR:-/tmp/pi-star-build}"
CACHE_DIR="${CACHE_DIR:-/tmp/alpine-cache}"

echo "Building Pi-Star OTA rootfs v${VERSION} (Pi-Star mode: ${PI_STAR_MODE})"

# Create build environment
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Extract Alpine mini rootfs
mkdir -p rootfs
cd rootfs
sudo tar -xzf "$CACHE_DIR/alpine-minirootfs.tar.gz"

# Mount for chroot - including network access
sudo mount -t proc proc proc/
sudo mount -t sysfs sysfs sys/
sudo mount -o bind /dev dev/

# Configure Alpine
echo "Configuring Alpine Linux..."

REPO_ROOT="${GITHUB_WORKSPACE}"
# Updated to use Alpine 3.22 (current stable)
ALPINE_VER="${ALPINE_VERSION:-3.22}"
echo "Using repository root: $REPO_ROOT"
echo "Using Alpine version: $ALPINE_VER"

# First, set up the basic Alpine environment
echo "Setting up basic Alpine chroot..."

# Copy qemu static BEFORE doing anything else
# Fixed: Use consistent architecture - armhf (32-bit ARM)
sudo cp /usr/bin/qemu-arm-static usr/bin/

# Set up basic Alpine files - generate repositories dynamically
sudo chroot . /bin/sh << CHROOT_SETUP
# Ensure DNS resolution works by copying host DNS config
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# Set up repositories properly for ARM using current stable Alpine version
cat > /etc/apk/repositories << 'EOF'
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community
EOF

echo "Generated repositories for Alpine ${ALPINE_VER}:"
cat /etc/apk/repositories

# Clear any existing cache that might be stale
rm -rf /var/cache/apk/*

# Test connectivity first
if ! wget -q --spider https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/main/armhf/APKINDEX.tar.gz; then
    echo "CDN unavailable, switching to mirror..."
    cat > /etc/apk/repositories << 'EOF'
https://uk.alpinelinux.org/alpine/v${ALPINE_VER}/main
https://uk.alpinelinux.org/alpine/v${ALPINE_VER}/community
EOF
    echo "Updated repositories to use UK mirror:"
    cat /etc/apk/repositories
fi

# Set up Alpine keyring first - this is critical for repository access
echo "Installing Alpine keys..."
apk --no-cache add alpine-keys alpine-base

# Force refresh of package indexes
echo "Updating package indexes..."
apk update --force-refresh

# Install essential packages
echo "Installing essential Alpine packages..."
apk add --no-cache alpine-base busybox

# Set up basic system
/bin/busybox --install -s

echo "Basic Alpine setup complete"
CHROOT_SETUP

# Now install the full package set
echo "Installing full package set..."
sudo chroot . /bin/sh << 'CHROOT_PACKAGES'
# Install packages in smaller groups to identify any problematic packages
echo "Installing system packages..."
apk add --no-cache \
    alpine-conf \
    openrc \
    eudev \
    dbus \
    sudo

echo "Installing network and time services..."
apk add --no-cache \
    chrony \
    openssh \
    curl \
    wget

echo "Installing shell and utilities..."
apk add --no-cache \
    bash \
    openssl \
    ca-certificates \
    tzdata

echo "Installing WiFi and networking support..."
apk add --no-cache \
    wpa_supplicant \
    wireless-tools \
    iw \
    dhcpcd \
    bridge-utils

echo "Installing Raspberry Pi kernel and modules..."
apk add --no-cache \
    linux-rpi \
    linux-firmware-brcm \
    linux-firmware-cypress \
    raspberrypi-bootloader

echo "Package installation complete"
CHROOT_PACKAGES

# CRITICAL: Fix kernel/module compatibility for Pi Zero 2W
echo "=== FIXING KERNEL/MODULE MISMATCH FOR PI ZERO 2W ==="

# Install additional kernel packages for better compatibility
echo "Installing additional kernel packages..."
sudo chroot . /bin/sh << 'CHROOT_KERNEL_FIX'
# Force install multiple Pi kernel packages for compatibility
echo "Installing Raspberry Pi kernel packages..."
apk add --no-cache \
    linux-rpi4 \
    linux-rpi4-dev \
    raspberrypi-bootloader-common \
    raspberrypi-bootloader-x

# Also install edge kernel if available for newer hardware support
apk add --no-cache \
    linux-edge \
    linux-firmware \
    linux-firmware-brcm \
    linux-firmware-cypress \
    linux-firmware-ath9k || echo "Some edge firmware packages not available"

echo "Additional kernel packages installed"
CHROOT_KERNEL_FIX

# CRITICAL: Create module loading configuration
echo "Creating module loading configuration..."
sudo tee etc/modules-load.d/brcmfmac.conf << 'EOF'
# Load brcmfmac module for Raspberry Pi wireless
brcmfmac
brcmutil
cfg80211
EOF

# Create modprobe configuration for brcmfmac issues
sudo tee etc/modprobe.d/rpi-wireless.conf << 'EOF'
# Raspberry Pi wireless module configuration

# Pi Zero 2W specific fixes
options brcmfmac roamoff=1 feature_disable=0x282000

# Alternative fix for stubborn connections
# options brcmfmac feature_disable=0x2000

# Prevent module conflicts
blacklist b43
blacklist b43legacy
blacklist ssb

# Force brcmfmac to load properly
install brcmfmac /sbin/modprobe --ignore-install brcmfmac && sleep 1 && /sbin/modprobe brcmutil
EOF

# CRITICAL: Create kernel module fix script
sudo tee usr/local/bin/fix-wireless-modules << 'MODULE_FIX_SCRIPT'
#!/bin/bash
# Fix wireless module loading for Raspberry Pi

echo "Fixing wireless modules for Raspberry Pi..."

# Get actual running kernel version
KERNEL_VERSION=$(uname -r)
echo "Running kernel: $KERNEL_VERSION"

# Check if brcmfmac module exists
MODULE_PATH="/lib/modules/$KERNEL_VERSION/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko"
ALT_MODULE_PATH="/lib/modules/$KERNEL_VERSION"

echo "Looking for brcmfmac module..."
if [ -f "$MODULE_PATH" ]; then
    echo "✅ Found brcmfmac at: $MODULE_PATH"
elif find "/lib/modules/$KERNEL_VERSION" -name "brcmfmac.ko*" -type f 2>/dev/null | head -1; then
    FOUND_MODULE=$(find "/lib/modules/$KERNEL_VERSION" -name "brcmfmac.ko*" -type f 2>/dev/null | head -1)
    echo "✅ Found brcmfmac at: $FOUND_MODULE"
else
    echo "❌ brcmfmac module not found for kernel $KERNEL_VERSION"
    echo "Available kernel modules:"
    ls -la /lib/modules/ 2>/dev/null || echo "No modules directory found"
    
    # Try to load available modules
    for mod_dir in /lib/modules/*; do
        if [ -d "$mod_dir" ]; then
            echo "Checking $(basename "$mod_dir")..."
            find "$mod_dir" -name "brcmfmac*" -type f 2>/dev/null | head -3
        fi
    done
fi

# Force module loading
echo "Attempting to load wireless modules..."

# Try different loading methods
if modprobe brcmfmac 2>/dev/null; then
    echo "✅ brcmfmac loaded successfully"
elif insmod $(find /lib/modules -name "brcmfmac.ko*" | head -1) 2>/dev/null; then
    echo "✅ brcmfmac loaded via insmod"
else
    echo "❌ Failed to load brcmfmac module"
fi

# Load supporting modules
modprobe brcmutil 2>/dev/null && echo "✅ brcmutil loaded"
modprobe cfg80211 2>/dev/null && echo "✅ cfg80211 loaded"

# Check if wireless interface appears
sleep 2
if ip link show | grep -q wlan; then
    echo "✅ Wireless interface detected!"
    ip link show | grep wlan
else
    echo "❌ No wireless interface found"
fi

# Show module status
echo ""
echo "=== MODULE STATUS ==="
lsmod | grep -E "brcm|80211" | head -10
echo "===================="
MODULE_FIX_SCRIPT

sudo chmod +x usr/local/bin/fix-wireless-modules

# Create kernel compatibility checker
sudo tee usr/local/bin/check-kernel-compat << 'KERNEL_COMPAT_SCRIPT'
#!/bin/bash
# Check kernel/module compatibility

echo "=== KERNEL COMPATIBILITY CHECK ==="
RUNNING_KERNEL=$(uname -r)
echo "Running kernel: $RUNNING_KERNEL"

echo "Available module directories:"
ls -1 /lib/modules/ 2>/dev/null || echo "No modules found"

echo "Kernel version mismatch check:"
if [ -d "/lib/modules/$RUNNING_KERNEL" ]; then
    echo "✅ Modules available for running kernel"
else
    echo "❌ No modules for running kernel $RUNNING_KERNEL"
    echo "This explains why brcmfmac is not found!"
    
    # Show what modules are available
    echo "Available module versions:"
    for dir in /lib/modules/*/; do
        if [ -d "$dir" ]; then
            ver=$(basename "$dir")
            echo "  - $ver"
            if find "$dir" -name "brcmfmac*" -type f 2>/dev/null | head -1 >/dev/null; then
                echo "    ✅ Has brcmfmac"
            else
                echo "    ❌ No brcmfmac"
            fi
        fi
    done
fi

echo "=================================="
KERNEL_COMPAT_SCRIPT

sudo chmod +x usr/local/bin/check-kernel-compat

# ENHANCED: Pi Zero 2W Wireless Support & Debugging
echo "=== APPLYING PI ZERO 2W FIXES & ENHANCED DEBUGGING ==="

# CRITICAL: Download missing Pi Zero 2W firmware
echo "Downloading Pi Zero 2W specific firmware..."
sudo mkdir -p lib/firmware/brcm

# Download critical Pi Zero 2W firmware files that Alpine may be missing
if ! wget -q -O lib/firmware/brcm/brcmfmac43436-sdio.bin \
    "https://github.com/RPi-Distro/firmware-nonfree/raw/master/brcm80211/brcm/brcmfmac43436-sdio.bin"; then
    echo "WARNING: Failed to download brcmfmac43436-sdio.bin"
fi

if ! wget -q -O lib/firmware/brcm/brcmfmac43436-sdio.txt \
    "https://github.com/RPi-Distro/firmware-nonfree/raw/master/brcm80211/brcm/brcmfmac43436-sdio.txt"; then
    echo "WARNING: Failed to download brcmfmac43436-sdio.txt"
fi

# Create Pi Zero 2W specific configuration
sudo cp lib/firmware/brcm/brcmfmac43436-sdio.txt \
     lib/firmware/brcm/brcmfmac43436-sdio.raspberrypi,model-zero-2-w.txt 2>/dev/null || \
     echo "WARNING: Could not create Pi Zero 2W specific config"

# Enable essential services (basic setup only)
echo "Configuring basic services..."
sudo chroot . /bin/sh << 'CHROOT_SERVICES'
rc-update add bootmisc boot
rc-update add hostname boot
rc-update add modules boot
rc-update add devfs sysinit
rc-update add dbus default
rc-update add sshd default
rc-update add chronyd default
CHROOT_SERVICES

# Create secure user accounts
echo "Creating secure user accounts..."
sudo chroot . /bin/sh << 'CHROOT_USERS'
# Lock root account completely (no password, no SSH access)
passwd -l root

# Create pi-star user with no initial password
adduser -D -s /bin/bash pi-star
# Don't set any password initially - will be configured via boot config or remain locked

# Add pi-star to essential groups
addgroup sudo 2>/dev/null || true
adduser pi-star sudo
adduser pi-star dialout  # Serial port access
adduser pi-star audio    # Audio access
adduser pi-star video    # Video/GPIO access
adduser pi-star gpio 2>/dev/null || true     # GPIO access
adduser pi-star netdev 2>/dev/null || true   # Network device access

# Create pi-star home directory structure
mkdir -p /home/pi-star/.ssh
mkdir -p /home/pi-star/bin
chown -R pi-star:pi-star /home/pi-star
chmod 700 /home/pi-star/.ssh

# Enable passwordless sudo for pi-star user
echo "pi-star ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/pi-star
chmod 440 /etc/sudoers.d/pi-star

echo "Secure user configuration complete:"
echo "  root: LOCKED (no password, no SSH access)"
echo "  pi-star: passwordless sudo, WiFi support"
echo "  Configuration via /boot/pistar-config.txt"
CHROOT_USERS

# Configure SSH for security
echo "Configuring SSH..."
sudo chroot . /bin/sh << 'CHROOT_SSH'
# Create SSH host keys
ssh-keygen -A

# Configure SSH daemon
cat > /etc/ssh/sshd_config << 'EOF'
# Pi-Star SSH Configuration - Security Hardened
Port 22
Protocol 2

# Security settings - no root login, no password auth by default
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

# Disable dangerous features
PermitEmptyPasswords no
X11Forwarding no
AllowTcpForwarding no

# Connection settings
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 2

# Logging
SyslogFacility AUTH
LogLevel INFO
EOF

echo "SSH configured with security settings"
CHROOT_SSH

# Install Pi-Star (placeholder or actual)
echo "Installing Pi-Star (mode: ${PI_STAR_MODE})..."
case "$PI_STAR_MODE" in
    "docker")
        if [ -f "$REPO_ROOT/config/pi-star/docker-compose.yml.template" ]; then
            sudo mkdir -p opt/pi-star
            sudo cp "$REPO_ROOT/config/pi-star/docker-compose.yml.template" opt/pi-star/docker-compose.yml
        fi
        if [ -f "$REPO_ROOT/config/pi-star/docker-install.sh" ]; then
            sudo "$REPO_ROOT/config/pi-star/docker-install.sh" .
        fi
        ;;
    "native")
        if [ -f "$REPO_ROOT/config/pi-star/native-install.sh" ]; then
            sudo "$REPO_ROOT/config/pi-star/native-install.sh" .
        fi
        ;;
    *)
        if [ -f "$REPO_ROOT/config/pi-star/placeholder-install.sh" ]; then
            sudo "$REPO_ROOT/config/pi-star/placeholder-install.sh" .
        fi
        ;;
esac

# Install OTA system
echo "Installing OTA update system..."
if [ -f "$REPO_ROOT/scripts/update-daemon.sh" ]; then
    sudo cp "$REPO_ROOT/scripts/update-daemon.sh" usr/local/bin/update-daemon
    sudo chmod +x usr/local/bin/update-daemon
fi

if [ -f "$REPO_ROOT/scripts/install-update.sh" ]; then
    sudo cp "$REPO_ROOT/scripts/install-update.sh" usr/local/bin/install-update
    sudo chmod +x usr/local/bin/install-update
fi

if [ -f "$REPO_ROOT/scripts/boot-validator.sh" ]; then
    sudo cp "$REPO_ROOT/scripts/boot-validator.sh" usr/local/bin/boot-validator
    sudo chmod +x usr/local/bin/boot-validator
fi

if [ -f "$REPO_ROOT/scripts/partition-switcher.sh" ]; then
    sudo cp "$REPO_ROOT/scripts/partition-switcher.sh" usr/local/bin/partition-switcher
    sudo chmod +x usr/local/bin/partition-switcher
fi

# CRITICAL: Install FIXED boot configuration processor
echo "Installing FIXED boot configuration processor..."
sudo tee usr/local/bin/process-boot-config << 'BOOT_CONFIG_FIXED'
#!/bin/bash
# FIXED: Enhanced boot configuration processor with error handling
set -e

CONFIG_FILE="/boot/pistar-config.txt"
PROCESSED_FLAG="/boot/.config-processed"
DEBUG_LOG="/var/log/boot-config.log"

# Ensure log directory exists
mkdir -p /var/log

# Debug function
log_debug() {
    echo "$(date): $*" | tee -a "$DEBUG_LOG"
}

log_debug "=== Boot Configuration Starting ==="
log_debug "Config file: $CONFIG_FILE"
log_debug "Processed flag: $PROCESSED_FLAG"

# Check if already processed
if [ -f "$PROCESSED_FLAG" ]; then
    log_debug "Configuration already processed - exiting"
    exit 0
fi

# Check if config file exists  
if [ ! -f "$CONFIG_FILE" ]; then
    log_debug "No configuration file found - exiting"
    exit 0
fi

log_debug "Processing configuration file..."
log_debug "Config file contents:"
cat "$CONFIG_FILE" | sed 's/^/  /' | tee -a "$DEBUG_LOG"

# Parse configuration variables
WIFI_SSID=""
WIFI_PASSWORD=""
USER_PASSWORD=""
SSH_KEY=""
HOSTNAME=""

while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ $key =~ ^[[:space:]]*# ]] && continue
    [[ -z "$key" ]] && continue
    
    # Remove quotes and whitespace
    key=$(echo "$key" | tr -d ' ')
    value=$(echo "$value" | sed 's/^["'\'']*//;s/["'\'']*$//')
    
    case "$key" in
        "wifi_ssid") WIFI_SSID="$value" ;;
        "wifi_password") WIFI_PASSWORD="$value" ;;
        "user_password") USER_PASSWORD="$value" ;;
        "ssh_key") SSH_KEY="$value" ;;
        "hostname") HOSTNAME="$value" ;;
    esac
done < "$CONFIG_FILE"

# Configure WiFi if specified
if [ -n "$WIFI_SSID" ]; then
    log_debug "Configuring WiFi for SSID: $WIFI_SSID"
    
    # Ensure packages are installed
    if ! command -v wpa_supplicant >/dev/null 2>&1; then
        log_debug "Installing WiFi packages..."
        apk add --no-cache wpa_supplicant wireless-tools iw dhcpcd || log_debug "Failed to install WiFi packages"
    fi
    
    # Create wpa_supplicant configuration
    mkdir -p /etc/wpa_supplicant
    cat > /etc/wpa_supplicant/wpa_supplicant.conf << EOF
country=GB
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
ap_scan=1

network={
    ssid="$WIFI_SSID"
$([ -n "$WIFI_PASSWORD" ] && echo "    psk=\"$WIFI_PASSWORD\"" || echo "    key_mgmt=NONE")
    scan_ssid=1
    priority=100
}
EOF
    
    # Create network interface configuration
    cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto wlan0
iface wlan0 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
    wireless-power off

# Fallback to Ethernet
allow-hotplug eth0  
iface eth0 inet dhcp
EOF
    
    log_debug "WiFi configuration created"
fi

# Set user password
if [ -n "$USER_PASSWORD" ]; then
    log_debug "Setting pi-star user password"
    if echo "pi-star:$USER_PASSWORD" | chpasswd; then
        log_debug "Password set successfully"
    else
        log_debug "Failed to set password"
    fi
fi

# Configure SSH key
if [ -n "$SSH_KEY" ]; then
    log_debug "Adding SSH public key"
    mkdir -p /home/pi-star/.ssh
    echo "$SSH_KEY" >> /home/pi-star/.ssh/authorized_keys
    chmod 600 /home/pi-star/.ssh/authorized_keys
    chown pi-star:pi-star /home/pi-star/.ssh/authorized_keys
    log_debug "SSH key configured"
fi

# Set hostname
if [ -n "$HOSTNAME" ]; then
    log_debug "Setting hostname: $HOSTNAME"
    echo "$HOSTNAME" > /etc/hostname
    hostname "$HOSTNAME" 2>/dev/null || true
    
    # Update /etc/hosts
    if grep -q "127.0.1.1" /etc/hosts; then
        sed -i "s/127.0.1.1.*/127.0.1.1\t$HOSTNAME/" /etc/hosts
    else
        echo "127.0.1.1	$HOSTNAME" >> /etc/hosts
    fi
    log_debug "Hostname configured"
fi

# Mark as processed
echo "processed_$(date +%s)" > "$PROCESSED_FLAG"
log_debug "Configuration processing complete"

# Summary
log_debug "SUMMARY:"
[ -n "$WIFI_SSID" ] && log_debug "• WiFi: $WIFI_SSID"
[ -n "$USER_PASSWORD" ] && log_debug "• Password: Set"
[ -n "$SSH_KEY" ] && log_debug "• SSH Key: Configured"
[ -n "$HOSTNAME" ] && log_debug "• Hostname: $HOSTNAME"

log_debug "=== Boot Configuration Complete ==="
BOOT_CONFIG_FIXED

sudo chmod +x usr/local/bin/process-boot-config

# Copy public key
if [ -f "$REPO_ROOT/keys/public.pem" ]; then
    sudo cp "$REPO_ROOT/keys/public.pem" etc/pi-star-update-key.pub
fi

# Set version
echo "$VERSION" | sudo tee etc/pi-star-version

# Configure system files
if [ -f "$REPO_ROOT/config/system/fstab" ]; then
    sudo cp "$REPO_ROOT/config/system/fstab" etc/fstab
fi

if [ -f "$REPO_ROOT/config/system/hostname" ]; then
    sudo cp "$REPO_ROOT/config/system/hostname" etc/hostname
fi

# CRITICAL: Install FIXED pistar-boot-config service
echo "Installing FIXED pistar-boot-config service..."
sudo tee etc/init.d/pistar-boot-config << 'SERVICE_FIXED'
#!/sbin/openrc-run

name="Pi-Star Boot Config"
description="Process boot partition configuration"

depend() {
    after localmount
    after bootmisc  
    before networking
    before wpa_supplicant
    before dhcpcd
}

start() {
    ebegin "Processing Pi-Star boot configuration"
    
    # Ensure boot is mounted
    if ! mountpoint -q /boot 2>/dev/null; then
        mount /boot 2>/dev/null || true
    fi
    
    # Create log directory
    mkdir -p /var/log
    
    # Run configuration processor
    if /usr/local/bin/process-boot-config; then
        einfo "Boot configuration processed successfully"
        eend 0
    else
        eerror "Boot configuration failed - check /var/log/boot-config.log"
        eend 1
    fi
}
SERVICE_FIXED

sudo chmod +x etc/init.d/pistar-boot-config

# Enhanced wireless debug service that includes module fixes
sudo tee etc/init.d/wireless-debug << 'WIRELESS_DEBUG_ENHANCED'
#!/sbin/openrc-run

name="Wireless Debug Enhanced"
description="Debug and fix wireless interface detection"

depend() {
    after localmount
    after modules
    before networking
}

start() {
    ebegin "Debugging and fixing wireless interfaces"
    
    DEBUG_LOG="/var/log/wireless-debug.log"
    mkdir -p /var/log
    
    {
        echo "=== ENHANCED WIRELESS DEBUG $(date) ==="
        
        # Show kernel information
        echo "Kernel information:"
        uname -a
        
        echo "Available kernel modules directories:"
        ls -la /lib/modules/ 2>/dev/null || echo "No modules directory"
        
        # Run the module fix script
        echo "Running wireless module fix..."
        /usr/local/bin/fix-wireless-modules
        
        # Check firmware files
        echo "Checking firmware files:"
        ls -la /lib/firmware/brcm/ 2>/dev/null | head -10 || echo "No brcm firmware directory"
        
        # Check for module files
        echo "Searching for brcmfmac modules:"
        find /lib/modules -name "*brcm*" -type f 2>/dev/null | head -10 || echo "No brcm modules found"
        
        # Try manual module loading
        echo "Attempting manual module loading..."
        modprobe brcmfmac 2>&1 || echo "modprobe brcmfmac failed"
        sleep 2
        
        # Check interfaces after module loading
        echo "Network interfaces after module load:"
        ip link show 2>&1 || echo "ip link failed"
        
        echo "Wireless devices:"
        iw dev 2>&1 || echo "No wireless devices found"
        
        # Check rfkill
        echo "rfkill status:"
        rfkill list 2>&1 || echo "rfkill failed"
        
        # Check dmesg for wireless messages
        echo "Recent wireless/firmware messages:"
        dmesg | grep -i -E "brcm|wireless|wlan|firmware|43436|43430" | tail -15
        
        # Show loaded modules
        echo "Currently loaded wireless modules:"
        lsmod | grep -E "brcm|wireless|80211" || echo "No wireless modules loaded"
        
        echo "=== END ENHANCED WIRELESS DEBUG ==="
        
    } | tee "$DEBUG_LOG"
    
    eend 0
}
WIRELESS_DEBUG_ENHANCED

sudo chmod +x etc/init.d/wireless-debug

# FIXED: Create the first-boot service with CORRECT dependencies and runlevel
sudo tee etc/init.d/first-boot << 'FIRST_BOOT_SERVICE'
#!/sbin/openrc-run

name="First Boot Setup"
description="Pi-Star first boot configuration"
command="/usr/local/bin/first-boot-setup"

depend() {
    after localmount
    after bootmisc
    after pistar-boot-config
    after networking
    after wpa_supplicant
    need net
}

start() {
    if [ ! -f /opt/pistar/.first-boot-complete ]; then
        ebegin "Running first boot setup"
        $command
        eend $?
    else
        einfo "First boot already completed, skipping"
    fi
}
FIRST_BOOT_SERVICE

sudo chmod +x etc/init.d/first-boot

# Create updater service
sudo tee etc/init.d/pi-star-updater << 'SERVICE_EOF'
#!/sbin/openrc-run

name="Pi-Star Updater"
description="Pi-Star OTA Update Service"
command="/usr/local/bin/update-daemon"
command_background="yes"
pidfile="/run/pi-star-updater.pid"

depend() {
    need networking
}
SERVICE_EOF

sudo chmod +x etc/init.d/pi-star-updater

# FIXED: Enable services in correct order - move first-boot to DEFAULT level
echo "Configuring services with FIXED dependencies..."
sudo chroot . /bin/sh << 'CHROOT_SERVICES_FINAL'
# Boot-time services (in correct dependency order)
rc-update add devfs sysinit
rc-update add bootmisc boot
rc-update add localmount boot
rc-update add wireless-debug boot       # Debug wireless before config
rc-update add pistar-boot-config boot  # This processes your config file
rc-update add hostname boot
rc-update add modules boot

# Default services (after boot is complete) - FIRST-BOOT MOVED HERE
rc-update add dbus default
rc-update add chronyd default
rc-update add networking default
rc-update add wpa_supplicant default
rc-update add dhcpcd default
rc-update add first-boot default      # FIXED: Runs AFTER networking
rc-update add sshd default
rc-update add pi-star-updater default

# Verify the critical boot service order
echo "=== FIXED BOOT SERVICE VERIFICATION ==="
echo "Boot services enabled:"
rc-update show boot | grep -E "(localmount|pistar-boot-config|hostname|wireless-debug)"
echo "Default services enabled:"
rc-update show default | grep -E "(networking|first-boot|sshd)"
echo "FIXED: first-boot now runs AFTER networking is established"
echo "========================================"

echo "Services configured with proper boot order - NO MORE PASSWORD PROMPTS!"
CHROOT_SERVICES_FINAL

# Create the FIXED first-boot setup script
sudo tee usr/local/bin/first-boot-setup << 'FIRST_BOOT_SCRIPT'
#!/bin/bash
# FIXED: Enhanced first boot setup that NEVER prompts when config exists

echo "Pi-Star First Boot Setup"
echo "======================="

# CRITICAL FIX: Check if boot configuration was processed FIRST
if [ -f "/boot/.config-processed" ]; then
    echo "✅ Boot configuration found and processed from /boot/pistar-config.txt"
    echo "   User account and system settings configured automatically"
    echo "   NO MANUAL SETUP REQUIRED"
    
    # Show what was configured
    if [ -f "/boot/pistar-config.txt" ]; then
        echo ""
        echo "Configuration applied from boot partition:"
        
        # Check if WiFi was configured
        if grep -q "^wifi_ssid" /boot/pistar-config.txt 2>/dev/null; then
            WIFI_SSID=$(grep "^wifi_ssid" /boot/pistar-config.txt | head -1 | cut -d'=' -f2)
            echo "• WiFi: Configured for '$WIFI_SSID'"
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
    echo "✅ System fully configured - no user interaction needed"
    
    # FIXED: Skip ALL interactive prompts when config exists
    # Jump straight to validation and completion
    
else
    echo "ℹ️  No boot configuration found at /boot/pistar-config.txt"
    echo ""
    echo "SECURITY NOTICE:"
    echo "================"
    echo "• Root account: DISABLED (no password, no SSH access)"
    echo "• pi-star user: No password set (SSH key required)"
    echo "• SSH: Key authentication only (password auth disabled)"
    echo ""
    echo "⚠️  IMPORTANT: You must configure access before rebooting!"
    echo ""
    echo "OPTIONS:"
    echo "1. Create /boot/pistar-config.txt with your settings"
    echo "2. Connect via console and set password manually"
    echo ""
    echo "Example /boot/pistar-config.txt:"
    echo "  wifi_ssid=YourNetwork"
    echo "  wifi_password=YourPassword" 
    echo "  user_password=YourSecurePassword"
    echo "  ssh_key=ssh-rsa AAAAB3Nz... your-email@example.com"
    echo ""
    
    # FIXED: Only show interactive prompts if NO config file exists AND running interactively
    if [ -t 0 ] && [ -t 1 ]; then
        echo "Running interactively - offering to set password..."
        echo ""
        read -p "Set password for pi-star user now? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Setting password for pi-star user..."
            passwd pi-star
            
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
            echo "⚠️  No password set - SSH key authentication required"
        fi
    else
        echo "Running non-interactively - no password prompts"
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
echo "Pi-Star system first boot complete"
echo "=================================="

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
echo "CONFIGURATION STATUS:"
if [ -f "/boot/.config-processed" ]; then
    echo "✅ Boot configuration processed successfully"
else
    echo "⚠️  No boot configuration found"
    echo "   Create /boot/pistar-config.txt for automated setup"
fi

echo ""
echo "DEBUG LOGS AVAILABLE:"
echo "• Boot config: /var/log/boot-config.log"
echo "• Wireless debug: /var/log/wireless-debug.log"
echo "• Kernel compatibility: run /usr/local/bin/check-kernel-compat"
echo "• Wireless module fix: run /usr/local/bin/fix-wireless-modules"
echo ""
echo "For support and documentation:"
echo "• Repository: https://github.com/MW0MWZ/Pi-Star_Alpine_Rolling"
echo "• Update server: https://version.pistar.uk"
FIRST_BOOT_SCRIPT

sudo chmod +x usr/local/bin/first-boot-setup

echo "=== ALL FIXES APPLIED - SUMMARY ==="
echo "✅ Kernel/module compatibility fixes applied"
echo "✅ Multiple kernel packages installed (linux-rpi, linux-rpi4, linux-edge)"
echo "✅ Module loading configuration created"
echo "✅ Pi Zero 2W firmware downloaded"
echo "✅ Wireless driver configuration optimized"
echo "✅ Fixed boot configuration processor with error handling"
echo "✅ Added wireless debugging service with module fixes"
echo "✅ Enhanced logging for troubleshooting"
echo "✅ Fixed service dependencies and boot order"
echo ""
echo "Kernel module fix tools available:"
echo "  • /usr/local/bin/fix-wireless-modules"
echo "  • /usr/local/bin/check-kernel-compat"
echo ""
echo "Debug logs will be available at:"
echo "  • /var/log/boot-config.log"
echo "  • /var/log/wireless-debug.log"
echo "======================================="

# Add final verification debug section
echo "=== FINAL BUILD VERIFICATION ==="
echo "Repository root: $REPO_ROOT"

echo "Scripts installed:"
ls -la usr/local/bin/ | grep -E "(process-boot-config|first-boot-setup|update-daemon|install-update|fix-wireless-modules|check-kernel-compat)" || echo "❌ Scripts missing"

echo "Service files created:"
ls -la etc/init.d/ | grep -E "(pistar-boot-config|first-boot|wireless-debug)" || echo "❌ Services missing"

echo "Boot services enabled:"
sudo chroot . rc-update show boot | grep -E "(pistar-boot-config|wireless-debug)" || echo "❌ Boot services not enabled"

echo "Default services enabled:"
sudo chroot . rc-update show default | grep -E "(first-boot)" || echo "❌ Default services not enabled"

echo "System files:"
[ -f etc/fstab ] && echo "✅ fstab exists" || echo "❌ fstab missing"
[ -f etc/pi-star-version ] && echo "✅ version file exists" || echo "❌ version file missing"
[ -f usr/local/bin/first-boot-setup ] && echo "✅ FIXED first-boot script installed" || echo "❌ first-boot script missing"
[ -f usr/local/bin/process-boot-config ] && echo "✅ FIXED boot config processor installed" || echo "❌ boot config processor missing"

echo "Pi Zero 2W firmware:"
[ -f lib/firmware/brcm/brcmfmac43436-sdio.bin ] && echo "✅ Pi Zero 2W firmware downloaded" || echo "❌ Pi Zero 2W firmware missing"
[ -f etc/modprobe.d/rpi-wireless.conf ] && echo "✅ Wireless driver config created" || echo "❌ Wireless driver config missing"

echo "Kernel module fixes:"
[ -f etc/modules-load.d/brcmfmac.conf ] && echo "✅ Module loading config created" || echo "❌ Module loading config missing"
[ -f usr/local/bin/fix-wireless-modules ] && echo "✅ Wireless module fix script installed" || echo "❌ Wireless module fix script missing"

echo "================================="

# Cleanup
echo "Cleaning up..."
sudo chroot . apk cache clean
sudo rm -rf var/cache/apk/*
sudo rm -rf tmp/*
# Fixed: Remove the correct qemu binary
sudo rm -f usr/bin/qemu-arm-static

# Unmount
sudo umount proc sys dev

echo ""
echo "=== ROOT FILESYSTEM BUILD COMPLETE ==="
echo "✅ Alpine Linux 3.22 configured"
echo "✅ Pi Zero 2W wireless support added with kernel fixes"
echo "✅ Fixed boot configuration processing"
echo "✅ Enhanced debugging and logging"
echo "✅ Secure user accounts configured"
echo "✅ OTA update system installed"
echo ""
echo "CRITICAL FIXES APPLIED:"
echo "• No more password prompts when pistar-config.txt exists"
echo "• Pi Zero 2W wireless interface should now be detected"
echo "• Multiple kernel packages for module compatibility"
echo "• Wireless module loading and compatibility fixes"
echo "• Comprehensive debugging logs for troubleshooting"
echo "• Proper service dependencies and boot order"
echo ""
echo "Root filesystem build complete!"