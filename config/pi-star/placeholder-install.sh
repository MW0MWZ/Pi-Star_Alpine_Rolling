#!/bin/bash
# Placeholder for Pi-Star installation

ROOTFS="$1"

echo "Installing Pi-Star placeholder..."

# Create pi-star user
sudo chroot "$ROOTFS" sh << 'CHROOT_EOF'
addgroup -g 1000 pi-star
adduser -D -u 1000 -G pi-star -s /bin/bash pi-star
echo "pi-star:pi-star123" | chpasswd
CHROOT_EOF

# Create directory structure
sudo mkdir -p "$ROOTFS/opt/pi-star"
sudo mkdir -p "$ROOTFS/var/log/pi-star"
sudo mkdir -p "$ROOTFS/etc/pi-star"

# Placeholder service
sudo tee "$ROOTFS/etc/init.d/pi-star" << 'SERVICE_EOF'
#!/sbin/openrc-run

name="Pi-Star Placeholder"
description="Pi-Star Digital Radio Platform (Placeholder)"

start() {
    ebegin "Starting Pi-Star placeholder"
    echo "Pi-Star placeholder service started" > /var/log/pi-star/placeholder.log
    echo "Visit https://github.com/MW0MWZ/Pi-Star_Alpine_Rolling for Pi-Star implementation"
    eend 0
}

stop() {
    ebegin "Stopping Pi-Star placeholder"
    eend 0
}
SERVICE_EOF

sudo chmod +x "$ROOTFS/etc/init.d/pi-star"
sudo chroot "$ROOTFS" rc-update add pi-star default

echo "Pi-Star placeholder installed"
