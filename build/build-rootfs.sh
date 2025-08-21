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

# Install boot configuration processor
if [ -f "$REPO_ROOT/scripts/process-boot-config.sh" ]; then
    sudo cp "$REPO_ROOT/scripts/process-boot-config.sh" usr/local/bin/process-boot-config
    sudo chmod +x usr/local/bin/process-boot-config
fi

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

# Create enhanced boot config service
sudo tee etc/init.d/pistar-boot-config << 'SERVICE_EOF'
#!/sbin/openrc-run

name="Pi-Star Boot Config"
description="Process boot partition configuration"
command="/usr/local/bin/process-boot-config"

depend() {
    after localmount
    after bootmisc
    before networking
    before wpa_supplicant
    before dhcpcd
    before first-boot
}

start() {
    ebegin "Processing Pi-Star boot configuration"
    $command
    eend $?
}
SERVICE_EOF

sudo chmod +x etc/init.d/pistar-boot-config

# Create the first-boot service with proper dependencies  
sudo tee etc/init.d/first-boot << 'FIRST_BOOT_SERVICE'
#!/sbin/openrc-run

name="First Boot Setup"
description="Pi-Star first boot configuration"
command="/usr/local/bin/first-boot-setup"

depend() {
    after localmount
    after bootmisc
    after pistar-boot-config
    before networking
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

# Enable all services in correct order - SINGLE UNIFIED CONFIGURATION
echo "Configuring services with proper dependencies..."
sudo chroot . /bin/sh << 'CHROOT_SERVICES_FINAL'
# Boot-time services (in correct dependency order)
rc-update add devfs sysinit
rc-update add bootmisc boot
rc-update add localmount boot
rc-update add pistar-boot-config boot
rc-update add first-boot boot
rc-update add hostname boot
rc-update add modules boot

# Default services (after boot is complete)
rc-update add dbus default
rc-update add chronyd default
rc-update add networking default
rc-update add wpa_supplicant default
rc-update add dhcpcd default
rc-update add sshd default
rc-update add pi-star-updater default

# Verify the critical boot service order
echo "=== BOOT SERVICE VERIFICATION ==="
echo "Boot services enabled:"
rc-update show boot | grep -E "(localmount|pistar-boot-config|first-boot|hostname)"
echo "================================="

echo "Services configured with proper boot order"
CHROOT_SERVICES_FINAL

# Add final verification debug section
echo "=== FINAL BUILD VERIFICATION ==="
echo "Repository root: $REPO_ROOT"

echo "Scripts installed:"
ls -la usr/local/bin/ | grep -E "(process-boot-config|first-boot-setup|update-daemon|install-update)" || echo "❌ Scripts missing"

echo "Service files created:"
ls -la etc/init.d/ | grep -E "(pistar-boot-config|first-boot)" || echo "❌ Services missing"

echo "Boot services enabled:"
sudo chroot . rc-update show boot | grep -E "(pistar-boot-config|first-boot)" || echo "❌ Boot services not enabled"

echo "System files:"
[ -f etc/fstab ] && echo "✅ fstab exists" || echo "❌ fstab missing"
[ -f etc/pi-star-version ] && echo "✅ version file exists" || echo "❌ version file missing"

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

echo "Root filesystem build complete!"
