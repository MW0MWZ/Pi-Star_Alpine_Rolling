#!/bin/bash
# Boot configuration processor script

set -e

CONFIG_FILE="/boot/pistar-config.txt"
PROCESSED_FLAG="/boot/.config-processed"

# Exit if already processed this boot
if [ -f "$PROCESSED_FLAG" ]; then
    exit 0
fi

# Exit if no config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No boot configuration found at $CONFIG_FILE"
    exit 0
fi

echo "Processing boot configuration from $CONFIG_FILE"

# Source the config file safely
while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ $key =~ ^[[:space:]]*# ]] && continue
    [[ -z "$key" ]] && continue
    
    # Remove quotes and whitespace
    key=$(echo "$key" | tr -d ' ')
    value=$(echo "$value" | sed 's/^["'\'']*//;s/["'\'']*$//')
    
    case "$key" in
        # Network Configuration
        "wifi_ssid")
            WIFI_SSID="$value"
            ;;
        "wifi_password")
            WIFI_PASSWORD="$value"
            ;;
        "wifi_country")
            WIFI_COUNTRY="$value"
            ;;
        "hostname")
            HOSTNAME="$value"
            ;;
        
        # User Configuration
        "user_password")
            USER_PASSWORD="$value"
            ;;
        "ssh_key")
            SSH_KEY="$value"
            ;;
        "enable_ssh_password")
            ENABLE_SSH_PASSWORD="$value"
            ;;
        
        # System Configuration
        "timezone")
            TIMEZONE="$value"
            ;;
        "locale")
            LOCALE="$value"
            ;;
        
        # Pi-Star Configuration (for future use)
        "callsign")
            CALLSIGN="$value"
            ;;
        "dmr_id")
            DMR_ID="$value"
            ;;
    esac
done < "$CONFIG_FILE"

# Apply Network Configuration
if [ -n "$WIFI_SSID" ] && [ -n "$WIFI_PASSWORD" ]; then
    echo "Configuring WiFi: $WIFI_SSID"
    
    # Install wpa_supplicant if not present
    apk add --no-cache wpa_supplicant wireless-tools
    
    # Configure wpa_supplicant
    cat > /etc/wpa_supplicant/wpa_supplicant.conf << EOF
country=${WIFI_COUNTRY:-GB}
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="${WIFI_SSID}"
    psk="${WIFI_PASSWORD}"
}
EOF
    
    # Configure interface
    cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto wlan0
iface wlan0 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF
    
    # Enable networking service
    rc-update add networking default
    rc-update add wpa_supplicant default
fi

# Set hostname
if [ -n "$HOSTNAME" ]; then
    echo "Setting hostname: $HOSTNAME"
    echo "$HOSTNAME" > /etc/hostname
    hostname "$HOSTNAME"
    
    # Update /etc/hosts
    sed -i "s/127.0.1.1.*/127.0.1.1\t$HOSTNAME/" /etc/hosts
fi

# Configure user password
if [ -n "$USER_PASSWORD" ]; then
    echo "Setting pi-star user password"
    echo "pi-star:$USER_PASSWORD" | chpasswd
    
    # Enable SSH password authentication if requested
    if [ "$ENABLE_SSH_PASSWORD" = "true" ] || [ "$ENABLE_SSH_PASSWORD" = "yes" ] || [ "$ENABLE_SSH_PASSWORD" = "1" ]; then
        echo "Enabling SSH password authentication"
        sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
        sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
    fi
fi

# Add SSH key
if [ -n "$SSH_KEY" ]; then
    echo "Adding SSH public key"
    mkdir -p /home/pi-star/.ssh
    echo "$SSH_KEY" >> /home/pi-star/.ssh/authorized_keys
    chmod 600 /home/pi-star/.ssh/authorized_keys
    chown pi-star:pi-star /home/pi-star/.ssh/authorized_keys
fi

# Set timezone
if [ -n "$TIMEZONE" ]; then
    echo "Setting timezone: $TIMEZONE"
    setup-timezone "$TIMEZONE"
fi

# Set locale
if [ -n "$LOCALE" ]; then
    echo "Setting locale: $LOCALE"
    # Alpine locale setup
    echo "$LOCALE" > /etc/locale.conf
fi

# Store Pi-Star specific config for later use
if [ -n "$CALLSIGN" ] || [ -n "$DMR_ID" ]; then
    echo "Storing Pi-Star configuration"
    mkdir -p /opt/pistar/config
    cat > /opt/pistar/config/boot-config.json << EOF
{
    "callsign": "${CALLSIGN:-}",
    "dmr_id": "${DMR_ID:-}",
    "configured_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
fi

# Mark configuration as processed
touch "$PROCESSED_FLAG"

echo "Boot configuration processing complete"

# Optional: Remove sensitive config file after processing
# rm -f "$CONFIG_FILE"