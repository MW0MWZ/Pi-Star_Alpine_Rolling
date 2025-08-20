#!/bin/sh
# Pi-Star Update Daemon

UPDATE_SERVER="${UPDATE_SERVER:-https://mw0mwz.github.io/Pi-Star_Alpine_Rolling}"
CHECK_INTERVAL="${CHECK_INTERVAL:-3600}"
DEVICE_ID=$(cat /etc/machine-id 2>/dev/null || echo "unknown")
CURRENT_VERSION=$(cat /etc/pi-star-version 2>/dev/null || echo "unknown")

check_for_updates() {
    LATEST_INFO=$(curl -s "${UPDATE_SERVER}/latest.json" || echo "")
    
    if [ -n "$LATEST_INFO" ]; then
        LATEST_VERSION=$(echo "$LATEST_INFO" | grep -o '"latest_version":"[^"]*' | cut -d'"' -f4)
        
        if [ -n "$LATEST_VERSION" ] && [ "$LATEST_VERSION" != "$CURRENT_VERSION" ]; then
            echo "Update available: $LATEST_VERSION"
            download_and_install "$LATEST_VERSION" "$LATEST_INFO"
        fi
    fi
}

download_and_install() {
    VERSION=$1
    INFO=$2
    
    DOWNLOAD_URL=$(echo "$INFO" | grep -o '"download_url":"[^"]*' | cut -d'"' -f4)
    SIGNATURE_URL=$(echo "$INFO" | grep -o '"signature_url":"[^"]*' | cut -d'"' -f4)
    
    echo "Downloading update: $VERSION"
    
    # Download update and signature
    curl -L -o "/tmp/pi-star-${VERSION}.tar.gz" "$DOWNLOAD_URL" || return 1
    curl -L -o "/tmp/pi-star-${VERSION}.tar.gz.sig" "$SIGNATURE_URL" || return 1
    
    # Verify signature
    if ! openssl dgst -sha256 -verify /etc/pi-star-update-key.pub \
         -signature "/tmp/pi-star-${VERSION}.tar.gz.sig" "/tmp/pi-star-${VERSION}.tar.gz"; then
        echo "Signature verification failed"
        return 1
    fi
    
    # Install update
    /usr/local/bin/install-update "/tmp/pi-star-${VERSION}.tar.gz" "$VERSION"
}

# Main loop
while true; do
    check_for_updates
    sleep "$CHECK_INTERVAL"
done
