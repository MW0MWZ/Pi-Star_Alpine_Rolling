#!/bin/bash
# Enhanced boot configuration processor for Pi-Star Alpine Rolling
set -e

CONFIG_FILE="/boot/pistar-config.txt"
PROCESSED_FLAG="/boot/.config-processed"

# Debug function
debug_boot_config() {
    echo "=== BOOT CONFIG DEBUG ==="
    echo "Current time: $(date)"
    echo "Config file exists: $([ -f "$CONFIG_FILE" ] && echo 'YES' || echo 'NO')"
    echo "Processed flag exists: $([ -f "$PROCESSED_FLAG" ] && echo 'YES' || echo 'NO')"
    
    if [ -f "$CONFIG_FILE" ]; then
        echo "Config file size: $(wc -l < "$CONFIG_FILE") lines"
        echo "Config file contents (first 10 lines):"
        head -10 "$CONFIG_FILE" | sed 's/^/  /'
    fi
    
    echo "Boot partition contents:"
    ls -la /boot/ | grep -E "(pistar|config|\.txt)" | sed 's/^/  /' || true
    
    echo "Process: $$, User: $(whoami), PWD: $(pwd)"
    echo "========================="
}

# Initialize variables
WIFI_NETWORKS=()
WIFI_COUNTRY=""
HOSTNAME=""
USER_PASSWORD=""
SSH_KEY=""
ENABLE_SSH_PASSWORD=""
TIMEZONE=""
LOCALE=""
CALLSIGN=""
DMR_ID=""
ENABLE_OPEN_NETWORKS="false"

# Parse configuration file
parse_config() {
    local network_index=0
    
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ $key =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        
        # Remove quotes and whitespace
        key=$(echo "$key" | tr -d ' ')
        value=$(echo "$value" | sed 's/^["'\'']*//;s/["'\'']*$//')
        
        case "$key" in
            # WiFi network entries (support multiple with priority)
            "wifi_ssid")
                WIFI_NETWORKS[$network_index]="ssid=$value"
                ;;
            "wifi_password")
                if [ ${#WIFI_NETWORKS[@]} -gt 0 ]; then
                    WIFI_NETWORKS[$((network_index))]="${WIFI_NETWORKS[$network_index]};psk=$value"
                    ((network_index++))
                fi
                ;;
            "wifi_ssid_"*)
                # Support numbered SSIDs: wifi_ssid_1, wifi_ssid_2, etc.
                local num=$(echo "$key" | sed 's/wifi_ssid_//')
                WIFI_NETWORKS[$num]="ssid=$value"
                ;;
            "wifi_password_"*)
                # Support numbered passwords: wifi_password_1, wifi_password_2, etc.
                local num=$(echo "$key" | sed 's/wifi_password_//')
                if [ -n "${WIFI_NETWORKS[$num]}" ]; then
                    WIFI_NETWORKS[$num]="${WIFI_NETWORKS[$num]};psk=$value"
                fi
                ;;
            
            # General WiFi settings
            "wifi_country")
                WIFI_COUNTRY="$value"
                ;;
            "enable_open_networks")
                ENABLE_OPEN_NETWORKS="$value"
                ;;
            
            # Network configuration
            "hostname")
                HOSTNAME="$value"
                ;;
            
            # User configuration
            "user_password")
                USER_PASSWORD="$value"
                ;;
            "ssh_key")
                SSH_KEY="$value"
                ;;
            "enable_ssh_password")
                ENABLE_SSH_PASSWORD="$value"
                ;;
            
            # System configuration
            "timezone")
                TIMEZONE="$value"
                ;;
            "locale")
                LOCALE="$value"
                ;;
            
            # Pi-Star configuration
            "callsign")
                CALLSIGN="$value"
                ;;
            "dmr_id")
                DMR_ID="$value"
                ;;
            
            # Debug flag
            "DEBUG_BOOT_CONFIG")
                if [ "$value" = "1" ] || [ "$value" = "true" ]; then
                    export DEBUG_BOOT_CONFIG=1
                fi
                ;;
        esac
    done < "$CONFIG_FILE"
}

# Configure WiFi with multiple networks and priorities
configure_wifi() {
    if [ ${#WIFI_NETWORKS[@]} -eq 0 ] && [ "$ENABLE_OPEN_NETWORKS" != "true" ]; then
        echo "No WiFi networks configured"
        return
    fi
    
    echo "Configuring WiFi with ${#WIFI_NETWORKS[@]} networks"
    
    # Install WiFi packages
    apk add --no-cache wpa_supplicant wireless-tools iw
    
    # Create wpa_supplicant configuration
    cat > /etc/wpa_supplicant/wpa_supplicant.conf << EOF
country=${WIFI_COUNTRY:-GB}
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
ap_scan=1

EOF
    
    # Add configured networks (higher index = higher priority)
    local priority=100
    for i in "${!WIFI_NETWORKS[@]}"; do
        local network="${WIFI_NETWORKS[$i]}"
        local ssid=$(echo "$network" | grep -o 'ssid=[^;]*' | cut -d'=' -f2)
        local psk=$(echo "$network" | grep -o 'psk=[^;]*' | cut -d'=' -f2)
        
        if [ -n "$ssid" ]; then
            echo "Adding WiFi network: $ssid (priority: $priority)"
            cat >> /etc/wpa_supplicant/wpa_supplicant.conf << EOF
network={
    ssid="$ssid"
$([ -n "$psk" ] && echo "    psk=\"$psk\"" || echo "    key_mgmt=NONE")
    priority=$priority
    scan_ssid=1
}

EOF
            ((priority+=10))
        fi
    done
    
    # Add support for open networks if enabled
    if [ "$ENABLE_OPEN_NETWORKS" = "true" ] || [ "$ENABLE_OPEN_NETWORKS" = "yes" ] || [ "$ENABLE_OPEN_NETWORKS" = "1" ]; then
        echo "Enabling connection to open networks"
        cat >> /etc/wpa_supplicant/wpa_supplicant.conf << EOF
# Connect to any open network (lowest priority)
network={
    key_mgmt=NONE
    priority=1
}

EOF
    fi
    
    # Configure network interface
    cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto wlan0
iface wlan0 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
    wpa-driver wext
    wireless-power off

# Fallback to Ethernet if available
allow-hotplug eth0
iface eth0 inet dhcp
EOF
    
    # Set up services
    rc-update add networking default
    rc-update add wpa_supplicant default
    
    # Enable WiFi interface
    ip link set wlan0 up 2>/dev/null || true
}

# Configure hostname
configure_hostname() {
    if [ -n "$HOSTNAME" ]; then
        echo "Setting hostname: $HOSTNAME"
        echo "$HOSTNAME" > /etc/hostname
        hostname "$HOSTNAME"
        
        # Update /etc/hosts
        if grep -q "127.0.1.1" /etc/hosts; then
            sed -i "s/127.0.1.1.*/127.0.1.1\t$HOSTNAME/" /etc/hosts
        else
            echo "127.0.1.1	$HOSTNAME" >> /etc/hosts
        fi
    fi
}

# Configure user account (never prompt if config exists)
configure_user() {
    echo "Configuring pi-star user account from boot config"
    
    # Set password if provided
    if [ -n "$USER_PASSWORD" ]; then
        echo "Setting pi-star user password from config"
        echo "pi-star:$USER_PASSWORD" | chpasswd
        
        # Enable SSH password authentication if requested
        if [ "$ENABLE_SSH_PASSWORD" = "true" ] || [ "$ENABLE_SSH_PASSWORD" = "yes" ] || [ "$ENABLE_SSH_PASSWORD" = "1" ]; then
            echo "Enabling SSH password authentication"
            sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
            sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
        fi
    else
        echo "No password set for pi-star user - SSH key authentication required"
    fi
    
    # Add SSH key if provided
    if [ -n "$SSH_KEY" ]; then
        echo "Adding SSH public key from config"
        mkdir -p /home/pi-star/.ssh
        echo "$SSH_KEY" >> /home/pi-star/.ssh/authorized_keys
        chmod 600 /home/pi-star/.ssh/authorized_keys
        chown pi-star:pi-star /home/pi-star/.ssh/authorized_keys
    fi
    
    # Ensure root account is properly locked (no password, no SSH access)
    echo "Ensuring root account is locked and secure"
    passwd -l root  # Lock root account
    
    # Ensure pi-star has passwordless sudo
    echo "pi-star ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/pi-star
    chmod 440 /etc/sudoers.d/pi-star
}

# Configure system settings
configure_system() {
    # Set timezone
    if [ -n "$TIMEZONE" ]; then
        echo "Setting timezone: $TIMEZONE"
        setup-timezone "$TIMEZONE"
    fi
    
    # Set locale
    if [ -n "$LOCALE" ]; then
        echo "Setting locale: $LOCALE"
        echo "$LOCALE" > /etc/locale.conf
    fi
}

# Store Pi-Star configuration
store_pistar_config() {
    if [ -n "$CALLSIGN" ] || [ -n "$DMR_ID" ]; then
        echo "Storing Pi-Star configuration for later use"
        mkdir -p /opt/pistar/config
        cat > /opt/pistar/config/boot-config.json << EOF
{
    "callsign": "${CALLSIGN:-}",
    "dmr_id": "${DMR_ID:-}",
    "configured_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "config_source": "boot_partition"
}
EOF
        chown -R pi-star:pi-star /opt/pistar/config
    fi
}

# Main execution
main() {
    echo "Starting enhanced boot configuration processing"
    echo "Config file: $CONFIG_FILE"
    echo "Processed flag: $PROCESSED_FLAG"
    
    # Call debug function if environment variable is set
    if [ "$DEBUG_BOOT_CONFIG" = "1" ]; then
        debug_boot_config
    fi
    
    # Check if already processed
    if [ -f "$PROCESSED_FLAG" ]; then
        echo "Configuration already processed this boot - exiting"
        exit 0
    fi
    
    # Check if config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "No boot configuration found at $CONFIG_FILE - exiting"
        exit 0
    fi
    
    echo "Processing configuration file..."
    
    # Parse the configuration file
    parse_config
    
    # Apply configurations
    configure_wifi
    configure_hostname
    configure_user
    configure_system
    store_pistar_config
    
    # Mark configuration as processed
    echo "Marking configuration as processed..."
    touch "$PROCESSED_FLAG"
    
    echo "Boot configuration processing complete"
    echo "Processed flag created: $PROCESSED_FLAG"
    echo "Configuration applied from: $CONFIG_FILE"
    
    # List what was actually configured
    echo ""
    echo "CONFIGURATION SUMMARY:"
    [ -n "$HOSTNAME" ] && echo "• Hostname: $HOSTNAME"
    [ ${#WIFI_NETWORKS[@]} -gt 0 ] && echo "• WiFi networks: ${#WIFI_NETWORKS[@]} configured"
    [ -n "$USER_PASSWORD" ] && echo "• User password: Set"
    [ -n "$SSH_KEY" ] && echo "• SSH key: Configured"
    [ -n "$TIMEZONE" ] && echo "• Timezone: $TIMEZONE"
    echo ""
}

# Run main function
main "$@"
