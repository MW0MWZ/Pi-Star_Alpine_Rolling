#!/bin/bash
set -e

VERSION="$1"
PI_STAR_MODE="$2"
BUILD_DIR="${BUILD_DIR:-/tmp/pi-star-build}"
CACHE_DIR="${CACHE_DIR:-/tmp/alpine-cache}"

echo "🚀 Building Pi-Star Alpine rootfs v${VERSION} (mode: ${PI_STAR_MODE})"
echo "🔧 PURE ALPINE USERLAND - No kernel packages (RaspberryPi OS provides hardware layer)"

# Create build environment
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Extract Alpine mini rootfs
echo "📦 Extracting Alpine base system..."
mkdir -p rootfs
cd rootfs
sudo tar -xzf "$CACHE_DIR/alpine-minirootfs.tar.gz" 2>/dev/null

# Mount for chroot
sudo mount -t proc proc proc/ 2>/dev/null
sudo mount -t sysfs sysfs sys/ 2>/dev/null
sudo mount -o bind /dev dev/ 2>/dev/null

# Configure Alpine
REPO_ROOT="${GITHUB_WORKSPACE}"
ALPINE_VER="${ALPINE_VERSION:-3.22}"

echo "🔧 Setting up Alpine chroot environment..."

# Copy qemu static
sudo cp /usr/bin/qemu-arm-static usr/bin/

# Set up basic Alpine environment
sudo chroot . /bin/sh << CHROOT_SETUP
# DNS setup
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf

# Alpine repositories  
cat > /etc/apk/repositories << 'EOF'
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community
EOF

# Test connectivity and fallback if needed
if ! wget -q --spider https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/main/armhf/APKINDEX.tar.gz 2>/dev/null; then
    cat > /etc/apk/repositories << 'EOF'
https://uk.alpinelinux.org/alpine/v${ALPINE_VER}/main
https://uk.alpinelinux.org/alpine/v${ALPINE_VER}/community
EOF
fi

# Install Alpine keyring and base
apk --no-cache add alpine-keys alpine-base >/dev/null 2>&1
apk update --force-refresh >/dev/null 2>&1
apk add --no-cache alpine-base busybox >/dev/null 2>&1
/bin/busybox --install -s >/dev/null 2>&1
CHROOT_SETUP

echo "📱 Installing Alpine userland packages (NO KERNEL PACKAGES)..."
sudo chroot . /bin/sh << 'CHROOT_PACKAGES'
# Core system packages (NO kernel packages)
apk add --no-cache \
    alpine-base \
    openrc \
    sudo \
    bash \
    openssl \
    ca-certificates \
    tzdata \
    chrony \
    openssh \
    wpa_supplicant \
    wireless-tools \
    iw \
    dhcpcd \
    curl \
    wget >/dev/null 2>&1

# NOTE: NOT installing linux-rpi or raspberrypi-bootloader
# RaspberryPi OS provides complete hardware layer
echo "✅ Pure Alpine userland installed (no kernel packages)"
CHROOT_PACKAGES

echo "📶 Configuring WiFi drivers (using RaspberryPi OS modules)..."
sudo tee etc/modprobe.d/brcmfmac.conf << 'EOF' >/dev/null
# Pi wireless configuration (modules provided by RaspberryPi OS)
options brcmfmac roamoff=1 feature_disable=0x282000

# Disable Bluetooth for resource savings
blacklist btbcm
blacklist hci_uart
blacklist btrtl
blacklist btintel
blacklist bluetooth
EOF

sudo tee etc/modules-load.d/pi-wireless.conf << 'EOF' >/dev/null
# WiFi modules for Pi (provided by RaspberryPi OS /lib/modules/)
brcmfmac
brcmutil
cfg80211
EOF

echo "⚙️ Configuring Alpine services..."
sudo chroot . /bin/sh << 'CHROOT_SERVICES' >/dev/null 2>&1
rc-update add devfs sysinit
rc-update add localmount boot
rc-update add bootmisc boot
rc-update add hostname boot
rc-update add modules boot
rc-update add chronyd default
rc-update add networking default
rc-update add sshd default
CHROOT_SERVICES

echo "👤 Creating secure user accounts..."
sudo chroot . /bin/sh << 'CHROOT_USERS'
# Lock root account
passwd -l root >/dev/null 2>&1

# Create pi-star user
adduser -D -s /bin/bash pi-star >/dev/null 2>&1
addgroup sudo 2>/dev/null || true
adduser pi-star sudo >/dev/null 2>&1
adduser pi-star dialout >/dev/null 2>&1
adduser pi-star audio >/dev/null 2>&1
adduser pi-star video >/dev/null 2>&1
adduser pi-star gpio 2>/dev/null || true
adduser pi-star netdev 2>/dev/null || true

# Set up home directory
mkdir -p /home/pi-star/.ssh
mkdir -p /home/pi-star/bin
chown -R pi-star:pi-star /home/pi-star
chmod 700 /home/pi-star/.ssh

# Enable passwordless sudo
echo "pi-star ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/pi-star
chmod 440 /etc/sudoers.d/pi-star
CHROOT_USERS

echo "🔐 Configuring SSH security..."
sudo chroot . /bin/sh << 'CHROOT_SSH'
# Generate SSH host keys
ssh-keygen -A >/dev/null 2>&1

# SSH configuration
cat > /etc/ssh/sshd_config << 'EOF'
Port 22
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
X11Forwarding no
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
CHROOT_SSH

echo "⭐ Installing Pi-Star (mode: ${PI_STAR_MODE})..."
case "$PI_STAR_MODE" in
    "docker")
        if [ -f "$REPO_ROOT/config/pi-star/docker-compose.yml.template" ]; then
            sudo mkdir -p opt/pi-star
            sudo cp "$REPO_ROOT/config/pi-star/docker-compose.yml.template" opt/pi-star/docker-compose.yml
        fi
        if [ -f "$REPO_ROOT/config/pi-star/docker-install.sh" ]; then
            sudo "$REPO_ROOT/config/pi-star/docker-install.sh" . >/dev/null 2>&1
        fi
        ;;
    "native")
        if [ -f "$REPO_ROOT/config/pi-star/native-install.sh" ]; then
            sudo "$REPO_ROOT/config/pi-star/native-install.sh" . >/dev/null 2>&1
        fi
        ;;
    *)
        if [ -f "$REPO_ROOT/config/pi-star/placeholder-install.sh" ]; then
            sudo "$REPO_ROOT/config/pi-star/placeholder-install.sh" . >/dev/null 2>&1
        fi
        ;;
esac

echo "🔄 Installing OTA update system..."
# Install update scripts
for script in update-daemon.sh install-update.sh boot-validator.sh partition-switcher.sh; do
    if [ -f "$REPO_ROOT/scripts/$script" ]; then
        sudo cp "$REPO_ROOT/scripts/$script" "usr/local/bin/$(basename $script .sh)"
        sudo chmod +x "usr/local/bin/$(basename $script .sh)"
    fi
done

echo "🔧 Installing boot configuration processor..."
sudo tee usr/local/bin/process-boot-config << 'BOOT_CONFIG_SCRIPT' >/dev/null
#!/bin/bash
set -e

CONFIG_FILE="/boot/firmware/pistar-config.txt"
PROCESSED_FLAG="/boot/firmware/.config-processed"
DEBUG_LOG="/var/log/boot-config.log"

mkdir -p /var/log

log_debug() {
    echo "$(date): $*" | tee -a "$DEBUG_LOG"
}

# Check if already processed or no config file
if [ -f "$PROCESSED_FLAG" ]; then
    exit 0
fi

if [ ! -f "$CONFIG_FILE" ]; then
    exit 0
fi

log_debug "Processing boot configuration..."

# Parse configuration
WIFI_SSID=""
WIFI_PASSWORD=""
USER_PASSWORD=""
SSH_KEY=""
HOSTNAME=""

while IFS='=' read -r key value; do
    [[ $key =~ ^[[:space:]]*# ]] && continue
    [[ -z "$key" ]] && continue
    
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

# Configure WiFi
if [ -n "$WIFI_SSID" ]; then
    log_debug "Configuring WiFi: $WIFI_SSID"
    
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
    
    cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto wlan0
iface wlan0 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
    wireless-power off

allow-hotplug eth0  
iface eth0 inet dhcp
EOF
fi

# Set user password
if [ -n "$USER_PASSWORD" ]; then
    log_debug "Setting pi-star user password"
    echo "pi-star:$USER_PASSWORD" | chpasswd
fi

# Configure SSH key
if [ -n "$SSH_KEY" ]; then
    log_debug "Adding SSH public key"
    mkdir -p /home/pi-star/.ssh
    echo "$SSH_KEY" >> /home/pi-star/.ssh/authorized_keys
    chmod 600 /home/pi-star/.ssh/authorized_keys
    chown pi-star:pi-star /home/pi-star/.ssh/authorized_keys
fi

# Set hostname
if [ -n "$HOSTNAME" ]; then
    log_debug "Setting hostname: $HOSTNAME"
    echo "$HOSTNAME" > /etc/hostname
    hostname "$HOSTNAME" 2>/dev/null || true
    
    if grep -q "127.0.1.1" /etc/hosts; then
        sed -i "s/127.0.1.1.*/127.0.1.1\t$HOSTNAME/" /etc/hosts
    else
        echo "127.0.1.1	$HOSTNAME" >> /etc/hosts
    fi
fi

echo "processed_$(date +%s)" > "$PROCESSED_FLAG"
log_debug "Boot configuration complete"
BOOT_CONFIG_SCRIPT

sudo chmod +x usr/local/bin/process-boot-config

# Copy public key if available
if [ -f "$REPO_ROOT/keys/public.pem" ]; then
    sudo cp "$REPO_ROOT/keys/public.pem" etc/pi-star-update-key.pub
fi

# Set version
echo "$VERSION" | sudo tee etc/pi-star-version >/dev/null

# Configure system files
if [ -f "$REPO_ROOT/config/system/hostname" ]; then
    sudo cp "$REPO_ROOT/config/system/hostname" etc/hostname
fi

echo "🔧 Installing system services..."
# Install service files
sudo tee etc/init.d/pistar-boot-config << 'SERVICE_BOOT_CONFIG' >/dev/null
#!/sbin/openrc-run

name="Pi-Star Boot Config"
description="Process boot partition configuration"

depend() {
    after localmount bootmisc  
    before networking wpa_supplicant dhcpcd
}

start() {
    ebegin "Processing Pi-Star boot configuration"
    
    if ! mountpoint -q /boot/firmware 2>/dev/null; then
        mount /boot/firmware 2>/dev/null || true
    fi
    
    mkdir -p /var/log
    
    if /usr/local/bin/process-boot-config; then
        eend 0
    else
        eend 1
    fi
}
SERVICE_BOOT_CONFIG

sudo tee etc/init.d/alpine-pi-setup << 'SERVICE_PI_SETUP' >/dev/null
#!/sbin/openrc-run

name="Alpine Pi Setup"
description="Pi hardware setup for Alpine with RaspberryPi OS modules"

depend() {
    after localmount modules
    before networking
}

start() {
    ebegin "Setting up Alpine for Pi hardware (using RaspberryPi OS modules)"
    
    # Load RaspberryPi OS modules
    modprobe brcmfmac 2>/dev/null || true
    modprobe brcmutil 2>/dev/null || true
    modprobe cfg80211 2>/dev/null || true
    
    # Disable bluetooth
    rmmod btbcm 2>/dev/null || true
    rmmod hci_uart 2>/dev/null || true
    rmmod bluetooth 2>/dev/null || true
    
    eend 0
}
SERVICE_PI_SETUP

sudo tee etc/init.d/first-boot << 'SERVICE_FIRST_BOOT' >/dev/null
#!/sbin/openrc-run

name="First Boot Setup"
description="Pi-Star first boot configuration"
command="/usr/local/bin/first-boot-setup"

depend() {
    after localmount bootmisc pistar-boot-config networking wpa_supplicant
    need net
}

start() {
    if [ ! -f /opt/pistar/.first-boot-complete ]; then
        ebegin "Running first boot setup"
        $command
        eend $?
    fi
}
SERVICE_FIRST_BOOT

sudo tee etc/init.d/pi-star-updater << 'SERVICE_UPDATER' >/dev/null
#!/sbin/openrc-run

name="Pi-Star Updater"
description="Pi-Star OTA Update Service"
command="/usr/local/bin/update-daemon"
command_background="yes"
pidfile="/run/pi-star-updater.pid"

depend() {
    need networking
}
SERVICE_UPDATER

# Make services executable
sudo chmod +x etc/init.d/pistar-boot-config
sudo chmod +x etc/init.d/alpine-pi-setup
sudo chmod +x etc/init.d/first-boot
sudo chmod +x etc/init.d/pi-star-updater

# Configure services
sudo chroot . /bin/sh << 'CHROOT_SERVICES_FINAL' >/dev/null 2>&1
rc-update add devfs sysinit
rc-update add localmount boot
rc-update add bootmisc boot
rc-update add alpine-pi-setup boot
rc-update add pistar-boot-config boot
rc-update add hostname boot
rc-update add modules boot

rc-update add chronyd default
rc-update add networking default
rc-update add wpa_supplicant default
rc-update add dhcpcd default
rc-update add sshd default
rc-update add first-boot default
rc-update add pi-star-updater default
CHROOT_SERVICES_FINAL

echo "🔧 Creating first-boot setup script..."
sudo tee usr/local/bin/first-boot-setup << 'FIRST_BOOT_SCRIPT' >/dev/null
#!/bin/bash

echo "Pi-Star Alpine + RaspberryPi OS Hybrid First Boot Setup"
echo "======================================================"

if [ -f "/boot/firmware/.config-processed" ]; then
    echo "✅ Boot configuration processed automatically"
    
    if [ -f "/boot/firmware/pistar-config.txt" ]; then
        echo ""
        echo "Configuration applied:"
        
        if grep -q "^wifi_ssid" /boot/firmware/pistar-config.txt 2>/dev/null; then
            WIFI_SSID=$(grep "^wifi_ssid" /boot/firmware/pistar-config.txt | head -1 | cut -d'=' -f2)
            echo "• WiFi: Configured for '$WIFI_SSID'"
        fi
        
        if grep -q "^user_password" /boot/firmware/pistar-config.txt 2>/dev/null; then
            echo "• User: Password set for pi-star user"
        fi
        
        if grep -q "^ssh_key" /boot/firmware/pistar-config.txt 2>/dev/null; then
            echo "• SSH: Public key authentication configured"
        fi
        
        if grep -q "^hostname" /boot/firmware/pistar-config.txt 2>/dev/null; then
            CONFIGURED_HOSTNAME=$(grep "^hostname" /boot/firmware/pistar-config.txt | cut -d'=' -f2)
            echo "• Hostname: Set to '$CONFIGURED_HOSTNAME'"
        fi
    fi
    
    echo ""
    echo "✅ System fully configured automatically"
else
    echo "ℹ️  No boot configuration found at /boot/firmware/pistar-config.txt"
    echo ""
    echo "SECURITY NOTICE:"
    echo "• Root account: DISABLED"
    echo "• pi-star user: No password set (SSH key required)"
    echo "• SSH: Key authentication only"
    echo ""
    echo "Create /boot/firmware/pistar-config.txt with your settings before rebooting!"
fi

if [ -f "/usr/local/bin/boot-validator" ]; then
    echo ""
    echo "Validating system boot..."
    /usr/local/bin/boot-validator
fi

mkdir -p /opt/pistar
touch /opt/pistar/.first-boot-complete

echo ""
echo "SYSTEM STATUS:"
echo "• Hostname: $(hostname)"
echo "• Active partition: $(cat /boot/firmware/ab_state 2>/dev/null || echo 'Unknown')"
echo "• Pi-Star version: $(cat /etc/pi-star-version 2>/dev/null || echo 'Unknown')"
echo "• Kernel: $(uname -r)"
echo "• Hardware layer: RaspberryPi OS"
echo "• Userland: Alpine Linux"

if command -v ip >/dev/null 2>&1; then
    echo "• Network interfaces:"
    ip addr show | grep "inet " | grep -v "127.0.0.1" | while read line; do
        echo "  $line"
    done
fi

echo "• SSH access:"
if grep -q "PasswordAuthentication yes" /etc/ssh/sshd_config 2>/dev/null; then
    echo "  Password authentication: ENABLED"
else
    echo "  Password authentication: DISABLED (key-only)"
fi

if [ -f "/home/pi-star/.ssh/authorized_keys" ] && [ -s "/home/pi-star/.ssh/authorized_keys" ]; then
    echo "  SSH keys: Configured"
else
    echo "  SSH keys: Not configured"
fi

echo ""
echo "Pi-Star Alpine + RaspberryPi OS hybrid first boot complete!"
FIRST_BOOT_SCRIPT

sudo chmod +x usr/local/bin/first-boot-setup

echo "🧹 Cleaning up..."
sudo chroot . apk cache clean >/dev/null 2>&1
sudo rm -rf var/cache/apk/* tmp/* >/dev/null 2>&1
sudo rm -f usr/bin/qemu-arm-static

# Unmount
sudo umount proc sys dev 2>/dev/null

echo ""
echo "✅ Pure Alpine userland build complete!"
echo "📁 Version: $VERSION"
echo "🔧 Mode: $PI_STAR_MODE"
echo "📦 Size: $(du -sh . | cut -f1)"
echo "🏗️ Hardware layer: RaspberryPi OS (added separately)"
echo "🐧 Userland: Pure Alpine Linux"

# Final verification
ESSENTIAL_FILES=(
    "etc/pi-star-version"
    "usr/local/bin/process-boot-config"
    "usr/local/bin/first-boot-setup"
    "etc/init.d/pistar-boot-config"
    "etc/init.d/first-boot"
)

echo "🔍 Verifying essential files..."
MISSING_FILES=0
for file in "${ESSENTIAL_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo "❌ Missing: $file"
        MISSING_FILES=$((MISSING_FILES + 1))
    fi
done

if [ $MISSING_FILES -eq 0 ]; then
    echo "✅ All essential files present"
else
    echo "⚠️  $MISSING_FILES essential files missing"
fi

echo ""
echo "🎉 Pure Alpine userland ready for RaspberryPi OS hardware layer!"