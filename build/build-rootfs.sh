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
# Fixed: Use consistent architecture - assuming ARM64/aarch64
sudo cp /usr/bin/qemu-aarch64-static usr/bin/

# Set up basic Alpine files - generate repositories dynamically
sudo chroot . /bin/sh << CHROOT_SETUP
# Ensure DNS resolution works by copying host DNS config
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# Test DNS resolution
echo "Testing DNS resolution inside chroot..."
nslookup dl-cdn.alpinelinux.org || echo "DNS test failed but continuing"

# Set up repositories properly for ARM64 using current stable Alpine version
# Try CDN first, then fallback mirrors if CDN fails
cat > /etc/apk/repositories << 'EOF'
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community
EOF

echo "Generated repositories for Alpine ${ALPINE_VER}:"
cat /etc/apk/repositories

# Clear any existing cache that might be stale
rm -rf /var/cache/apk/*

# Test connectivity first
if ! wget -q --spider https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/main/aarch64/APKINDEX.tar.gz; then
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
apk --no-cache add alpine-keys || {
    echo "Failed to add alpine-keys, trying with --force-broken-world"
    apk --no-cache --force-broken-world add alpine-keys
}

# Add alpine-base immediately after keys
apk --no-cache add alpine-base || {
    echo "Failed to add alpine-base, trying alternative approach"
    apk --no-cache --force-broken-world add alpine-base
}

# Force refresh of package indexes with retries
echo "Updating package indexes..."
for i in 1 2 3; do
    if apk update --force-refresh; then
        echo "Package index update successful on attempt $i"
        break
    else
        echo "Package index update failed on attempt $i"
        if [ $i -eq 3 ]; then
            echo "All update attempts failed, but continuing..."
        else
            sleep 5
        fi
    fi
done

# Install essential packages
echo "Installing essential Alpine packages..."
apk add --no-cache alpine-base busybox || {
    echo "Standard install failed, trying with --force-broken-world"
    apk add --no-cache --force-broken-world alpine-base busybox
}

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
    dbus

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
echo "Cleaning up..."
sudo chroot . apk cache clean
sudo rm -rf var/cache/apk/*
sudo rm -rf tmp/*
# Fixed: Remove the correct qemu binary
sudo rm -f usr/bin/qemu-aarch64-static

# Unmount
sudo umount proc sys dev

echo "Root filesystem build complete!"