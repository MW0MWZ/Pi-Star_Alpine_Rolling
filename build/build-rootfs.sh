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

# Mount for chroot
sudo mount -t proc proc proc/
sudo mount -t sysfs sysfs sys/
sudo mount -o bind /dev dev/

# Copy qemu static
sudo cp /usr/bin/qemu-arm-static usr/bin/

# Configure Alpine
echo "Configuring Alpine Linux..."

# We're currently in BUILD_DIR/rootfs, so repository root is at GITHUB_WORKSPACE
REPO_ROOT="${GITHUB_WORKSPACE}"
echo "Using repository root: $REPO_ROOT"

if [ ! -f "$REPO_ROOT/config/alpine/repositories" ]; then
    echo "ERROR: Cannot find repositories file at: $REPO_ROOT/config/alpine/repositories"
    echo "Current directory: $(pwd)"
    echo "GITHUB_WORKSPACE: ${GITHUB_WORKSPACE:-not set}"
    echo "Available files in GITHUB_WORKSPACE:"
    ls -la "$REPO_ROOT/" 2>/dev/null || echo "GITHUB_WORKSPACE directory not accessible"
    echo "Available files in config:"
    ls -la "$REPO_ROOT/config/" 2>/dev/null || echo "config directory not found"
    exit 1
fi

sudo cp "$REPO_ROOT/config/alpine/repositories" etc/apk/repositories

# Install base packages using the host architecture first
echo "Installing base packages..."

# Install packages in host environment first
sudo apk update
sudo apk add --no-cache \
    alpine-base \
    alpine-conf \
    busybox \
    openrc \
    eudev \
    dbus \
    chrony \
    openssh \
    curl \
    wget \
    bash \
    openssl \
    ca-certificates \
    tzdata

# Now copy the installed packages to the chroot
echo "Setting up chroot environment..."
sudo chroot . sh << 'CHROOT_EOF'
# Just setup the basic services, packages are already installed
rc-update add bootmisc boot
rc-update add hostname boot
rc-update add modules boot
rc-update add devfs sysinit
rc-update add dbus default
rc-update add sshd default
rc-update add chronyd default
CHROOT_EOF

# Install Pi-Star (placeholder or actual)
echo "Installing Pi-Star (mode: ${PI_STAR_MODE})..."
case "$PI_STAR_MODE" in
    "docker")
        sudo cp "$REPO_ROOT/config/pi-star/docker-compose.yml.template" opt/pi-star/docker-compose.yml
        sudo "$REPO_ROOT/config/pi-star/docker-install.sh" .
        ;;
    "native")
        sudo "$REPO_ROOT/config/pi-star/native-install.sh" .
        ;;
    *)
        sudo "$REPO_ROOT/config/pi-star/placeholder-install.sh" .
        ;;
esac

# Install OTA system
echo "Installing OTA update system..."
sudo cp "$REPO_ROOT/scripts/update-daemon.sh" usr/local/bin/update-daemon
sudo cp "$REPO_ROOT/scripts/install-update.sh" usr/local/bin/install-update
sudo cp "$REPO_ROOT/scripts/boot-validator.sh" usr/local/bin/boot-validator
sudo cp "$REPO_ROOT/scripts/partition-switcher.sh" usr/local/bin/partition-switcher

sudo chmod +x usr/local/bin/update-daemon
sudo chmod +x usr/local/bin/install-update
sudo chmod +x usr/local/bin/boot-validator
sudo chmod +x usr/local/bin/partition-switcher

# Copy public key
sudo cp "$REPO_ROOT/keys/public.pem" etc/pi-star-update-key.pub

# Set version
echo "$VERSION" | sudo tee etc/pi-star-version

# Configure system files
sudo cp "$REPO_ROOT/config/system/fstab" etc/fstab
sudo cp "$REPO_ROOT/config/system/hostname" etc/hostname

# Create services
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
sudo chroot . rc-update add pi-star-updater default

# Cleanup
sudo chroot . apk cache clean
sudo rm -rf var/cache/apk/*
sudo rm -rf tmp/*
sudo rm usr/bin/qemu-arm-static

# Unmount
sudo umount proc sys dev

echo "Root filesystem build complete!"
