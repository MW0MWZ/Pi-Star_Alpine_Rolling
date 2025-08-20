#!/bin/bash
set -e

VERSION="$1"
ROOTFS_DIR="$2"
OUTPUT_DIR="$3"

if [ -z "$VERSION" ] || [ -z "$ROOTFS_DIR" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: $0 <version> <rootfs_dir> <output_dir>"
    echo "Example: $0 2024.01.15 /tmp/pi-star-build/rootfs output"
    exit 1
fi

echo "Packaging Pi-Star update v${VERSION}..."

# Get absolute paths to avoid confusion
ROOTFS_DIR="$(cd "$ROOTFS_DIR" && pwd)"
OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"

# Verify rootfs directory exists and is readable
if [ ! -d "$ROOTFS_DIR" ] || [ ! -r "$ROOTFS_DIR" ]; then
    echo "Error: Rootfs directory $ROOTFS_DIR does not exist or is not readable"
    exit 1
fi

# Verify output directory exists and is writable
if [ ! -d "$OUTPUT_DIR" ] || [ ! -w "$OUTPUT_DIR" ]; then
    echo "Error: Cannot create or write to output directory $OUTPUT_DIR"
    exit 1
fi

# Set variables
PACKAGE_NAME="pi-star-${VERSION}.tar.gz"
PACKAGE_PATH="${OUTPUT_DIR}/${PACKAGE_NAME}"
SIGNATURE_PATH="${PACKAGE_PATH}.sig"

echo "Creating package: $PACKAGE_PATH"
echo "From rootfs: $ROOTFS_DIR"

# Create the update package
echo "Creating tarball..."
tar -czf "$PACKAGE_PATH" \
    -C "$ROOTFS_DIR" \
    --exclude="proc/*" \
    --exclude="sys/*" \
    --exclude="dev/*" \
    --exclude="tmp/*" \
    --exclude="var/cache/*" \
    --exclude="var/log/*" \
    --exclude="run/*" \
    --exclude="mnt/*" \
    --exclude="media/*" \
    --owner=0 \
    --group=0 \
    .

# Verify the package was created
if [ ! -f "$PACKAGE_PATH" ]; then
    echo "Error: Failed to create package $PACKAGE_PATH"
    exit 1
fi

# Get package size
PACKAGE_SIZE=$(stat -c%s "$PACKAGE_PATH")
echo "Package created successfully: $PACKAGE_NAME ($(numfmt --to=iec-i --suffix=B $PACKAGE_SIZE))"

# Sign the package if private key exists
PRIVATE_KEY_PATH="${GITHUB_WORKSPACE}/keys/private.pem"
if [ -f "$PRIVATE_KEY_PATH" ]; then
    echo "Signing package with private key..."
    openssl dgst -sha256 -sign "$PRIVATE_KEY_PATH" -out "$SIGNATURE_PATH" "$PACKAGE_PATH"
    
    if [ -f "$SIGNATURE_PATH" ]; then
        echo "Package signed successfully: ${PACKAGE_NAME}.sig"
        
        # Verify signature if public key exists
        PUBLIC_KEY_PATH="${GITHUB_WORKSPACE}/keys/public.pem"
        if [ -f "$PUBLIC_KEY_PATH" ]; then
            echo "Verifying signature..."
            if openssl dgst -sha256 -verify "$PUBLIC_KEY_PATH" -signature "$SIGNATURE_PATH" "$PACKAGE_PATH"; then
                echo "Signature verification successful"
            else
                echo "Warning: Signature verification failed"
                exit 1
            fi
        fi
    else
        echo "Error: Failed to create signature"
        exit 1
    fi
else
    echo "Warning: Private key not found at $PRIVATE_KEY_PATH - package will not be signed"
fi

# Generate checksums
echo "Generating checksums..."
cd "$OUTPUT_DIR"
sha256sum "$PACKAGE_NAME" > "${PACKAGE_NAME}.sha256"
md5sum "$PACKAGE_NAME" > "${PACKAGE_NAME}.md5"

echo "Generated checksums:"
cat "${PACKAGE_NAME}.sha256"
cat "${PACKAGE_NAME}.md5"

# Create package manifest
cat > "package-manifest.json" << EOF
{
    "package": {
        "name": "$PACKAGE_NAME",
        "version": "$VERSION",
        "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
        "size": $PACKAGE_SIZE,
        "sha256": "$(cut -d' ' -f1 ${PACKAGE_NAME}.sha256)",
        "md5": "$(cut -d' ' -f1 ${PACKAGE_NAME}.md5)"
    },
    "signature": {
        "file": "${PACKAGE_NAME}.sig",
        "algorithm": "SHA256withRSA",
        "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    },
    "build": {
        "rootfs_source": "$ROOTFS_DIR",
        "build_host": "$(hostname)",
        "build_user": "$(whoami)",
        "git_commit": "${GITHUB_SHA:-unknown}",
        "alpine_version": "${ALPINE_VERSION:-unknown}",
        "architecture": "${BUILD_ARCH:-unknown}"
    }
}
EOF

echo "Package manifest created: package-manifest.json"

# List final output files
echo ""
echo "Package contents:"
ls -la "$OUTPUT_DIR"

echo ""
echo "Package details:"
echo "  Version: $VERSION"
echo "  Size: $(numfmt --to=iec-i --suffix=B $PACKAGE_SIZE)"
echo "  Files: $(tar -tzf "$PACKAGE_PATH" | wc -l) files"
echo "  Package: $PACKAGE_PATH"
if [ -f "$SIGNATURE_PATH" ]; then
    echo "  Signature: $SIGNATURE_PATH"
fi

echo ""
echo "Packaging complete!"