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

# Configure Alpine
echo "Configuring Alpine Linux..."

REPO_ROOT="${GITHUB_WORKSPACE}"
ALPINE_VER="${ALPINE_VERSION:-3.19}"
echo "Using repository root: $REPO_ROOT"
echo "Using Alpine version: $ALPINE_VER"

# First, set up the basic Alpine environment
echo "Setting up basic Alpine chroot..."

# Copy qemu static BEFORE doing anything else
sudo cp /usr/bin/qemu-arm-static usr/bin/

# Set up basic Alpine files - generate repositories dynamically
sudo chroot . /bin/sh << CHROOT_SETUP
# Set up repositories properly for armhf using environment variable
echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/main" > /etc/apk/repositories
echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community" >> /etc/apk/repositories

echo "Generated repositories:"
cat /etc/apk/repositories

# Set up Alpine keyring first
apk --no-cache add alpine-keys

# Now try to update package lists
apk update

# Install absolutely essential packages first
apk add --no-cache alpine-base busybox

# Set up basic system
/bin/busybox --install -s

echo "Basic Alpine setup complete"
CHROOT_SETUP

# Now install the full package set
echo "Installing full package set..."
sudo chroot . /bin/sh << 'CHROOT_PACKAGES'
apk add --no-cache \
    alpine-conf \
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

echo "Package installation complete"
CHROOT_PACKAGES

# Enable essential services
echo "Configuring services..."
sudo chroot . /bin/sh << 'CHROOT_SERVICES'
rc-update add bootmisc boot
rc-update add hostname boot
rc-update add modules boot
rc-update add devfs sysinit
rc-update add dbus default
rc-update add sshd default
rc-update add chronyd default
CHROOT_SERVICES

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
