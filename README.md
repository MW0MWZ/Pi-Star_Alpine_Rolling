# Pi-Star Alpine Rolling

A modern, Alpine Linux-based OTA (Over-The-Air) update system for Pi-Star digital radio platform.

## Features

- **A/B Partition Updates**: Atomic updates with automatic rollback on failure
- **Universal Pi Support**: Works on all Raspberry Pi models (Pi Zero W to Pi 5)
- **GitHub-Hosted**: Complete CI/CD and distribution via GitHub (100% free!)
- **Cryptographically Signed**: RSA-signed update packages for security
- **Router-Grade Reliability**: Never brick your device, always recoverable

## Architecture

### Partition Layout
```
/dev/mmcblk0p1    256MB   Boot (FAT32)           - Universal boot partition
/dev/mmcblk0p2    2.5GB   RootFS-A (ext4)        - Pi-Star System A  
/dev/mmcblk0p3    2.5GB   RootFS-B (ext4)        - Pi-Star System B
/dev/mmcblk0p4    2GB     Data (ext4)            - Persistent user data
```

### Update Process
1. Device checks GitHub Pages for latest version
2. Downloads update package from GitHub Releases
3. Verifies cryptographic signature
4. Installs to inactive partition
5. Switches boot partition and reboots
6. Validates successful boot or auto-rollback

## Quick Start

### For Repository Setup
1. **Upload to GitHub**: Extract and push this repository
2. **Configure Secrets**: Add `UPDATE_PRIVATE_KEY` and `UPDATE_PUBLIC_KEY`
3. **Enable Pages**: Repository Settings → Pages → Deploy from GitHub Actions
4. **Test Build**: Create a version tag to trigger first build

### Generate Signing Keys
```bash
# Generate private key (keep this SECRET!)
openssl genpkey -algorithm RSA -out private.pem -pkcs8 -aes256

# Extract public key
openssl rsa -pubout -in private.pem -out public.pem
```

Add to GitHub Secrets:
- `UPDATE_PRIVATE_KEY`: Contents of `private.pem`
- `UPDATE_PUBLIC_KEY`: Contents of `public.pem`

## Building Updates

### Automatic Builds (Recommended)
Push a version tag to trigger automatic build:
```bash
git tag v2024.01.15
git push origin v2024.01.15
```

### Manual Builds
Use GitHub Actions workflow dispatch:
1. Go to Actions tab
2. Select "Build Pi-Star OTA Release"
3. Click "Run workflow"
4. Enter version and Pi-Star mode

## Pi-Star Integration

Currently uses placeholder installation. To integrate actual Pi-Star:

### Docker Mode (Recommended)
1. Create Pi-Star Docker containers
2. Update `config/pi-star/docker-install.sh`
3. Set workflow to use `pi_star_mode: docker`

### Native Mode
1. Create native installation script
2. Update `config/pi-star/native-install.sh`  
3. Set workflow to use `pi_star_mode: native`

## Device Commands

### Manual Partition Switching
```bash
# Switch to partition A
sudo /usr/local/bin/partition-switcher A

# Switch to partition B
sudo /usr/local/bin/partition-switcher B

# Check current partition
cat /boot/active_partition
```

### Update System
```bash
# Check for updates manually
sudo /usr/local/bin/update-daemon

# Install specific update
sudo /usr/local/bin/install-update /path/to/update.tar.gz version

# Validate current boot
sudo /usr/local/bin/boot-validator
```

## Development

### Repository Structure
```
├── .github/workflows/     # GitHub Actions CI/CD
├── build/                 # Build scripts
├── config/               # System and Pi-Star configurations  
├── scripts/              # OTA update system scripts
├── server/               # GitHub Pages update server
└── keys/                 # Signing keys (GitHub Secrets)
```

### Local Testing
```bash
# Test build scripts
sudo chmod +x build/*.sh
sudo ./build/build-rootfs.sh "test-$(date +%s)" "placeholder"

# Validate package
openssl dgst -sha256 -verify public.pem \
  -signature update.tar.gz.sig update.tar.gz
```

## Cost Analysis

- **GitHub (this solution): $0/month**
- **Traditional cloud hosting: $50-500/month** 
- **Commercial OTA platforms: $160,000+/month**

## Security Features

- RSA-2048 signature verification on all updates
- HTTPS transport via GitHub's infrastructure
- Atomic updates prevent corruption
- Automatic rollback on boot failure
- Cryptographically signed release chain

## Support

- **Issues**: [GitHub Issues](https://github.com/MW0MWZ/Pi-Star_Alpine_Rolling/issues)
- **Discussions**: [GitHub Discussions](https://github.com/MW0MWZ/Pi-Star_Alpine_Rolling/discussions)
- **Documentation**: This README and inline code comments

## License

This project is open source. See LICENSE file for details.

## Contributing

1. Fork the repository
2. Create feature branch (`git checkout -b feature/amazing-feature`)
3. Test changes with workflow dispatch
4. Submit pull request

## Acknowledgments

- Alpine Linux project for the minimal, secure base OS
- GitHub for providing free CI/CD and hosting infrastructure
- Pi-Star community for the digital radio platform
