#!/bin/bash
set -e

VERSION="$1"
ROOTFS_DIR="$2"
OUTPUT_DIR="$3"

echo "Packaging Pi-Star update v${VERSION}..."

mkdir -p "$OUTPUT_DIR"

# Create tarball
cd "$ROOTFS_DIR"
sudo tar --numeric-owner -czf "$OUTPUT_DIR/pi-star-${VERSION}.tar.gz" .

# Sign the package
cd "$OUTPUT_DIR"
openssl dgst -sha256 -sign ../keys/private.pem \
    -out "pi-star-${VERSION}.tar.gz.sig" \
    "pi-star-${VERSION}.tar.gz"

echo "Package created:"
echo "  File: $OUTPUT_DIR/pi-star-${VERSION}.tar.gz"
echo "  Size: $(du -h $OUTPUT_DIR/pi-star-${VERSION}.tar.gz | cut -f1)"
echo "  Signature: $OUTPUT_DIR/pi-star-${VERSION}.tar.gz.sig"
