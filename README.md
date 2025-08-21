# Pi-Star Alpine Rolling

A modern, Alpine Linux-based OTA (Over-The-Air) update system for Pi-Star digital radio platform with secure boot configuration and OS/Pi-Star separation.

## Features

- **A/B Partition Updates**: Atomic updates with automatic rollback on failure
- **Universal Pi Support**: Works on all Raspberry Pi models (Pi Zero W to Pi 5)
- **GitHub-Hosted**: Complete CI/CD and distribution via GitHub (100% free!)
- **Cryptographically Signed**: RSA-signed update packages for security
- **Router-Grade Reliability**: Never brick your device, always recoverable
- **Secure Boot Configuration**: Configure WiFi, passwords, and settings via accessible boot partition
- **OS/Pi-Star Separation**: Independent update cycles for system and application components
- **2GB SD Card Compatible**: Optimized partition layout fits standard 2GB cards

## Architecture

### Partition Layout (2GB SD Card Compatible)
```
/dev/mmcblk0p1    128MB   Boot (FAT32)           - Pi firmware + configuration
/dev/mmcblk0p2    650MB   RootFS-A (ext4)        - Pi-Star System A  
/dev/mmcblk0p3    650MB   RootFS-B (ext4)        - Pi-Star System B
/dev/mmcblk0p4    500MB   Data (ext4)            - Persistent Pi-Star data
```
**Total: ~1.93GB** (fits comfortably on 2GB SD cards)

### Security Model
- **No default passwords**: System boots with secure defaults
- **Passwordless sudo**: pi-star user has full administrative access
- **SSH key authentication**: Password auth disabled by default
- **Boot-time configuration**: Secure setup via accessible boot partition

### OS/Pi-Star Separation
- **OS Updates**: Replace root partition A/B without affecting Pi-Star
- **Pi-Star Updates**: Update application independently of OS
- **Persistent Data**: Configuration and logs survive OS updates
- **Separate Lifecycles**: Upgrade OS and Pi-Star on different schedules

### Update Process
1. Device checks GitHub Pages for latest version
2. Downloads update package from GitHub Releases  
3. Verifies cryptographic signature
4. Installs to inactive partition (A ↔ B)
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

## SD Card Setup

### Download and Flash
1. Download latest image from [Releases](https://github.com/MW0MWZ/Pi-Star_Alpine_Rolling/releases)
2. Flash to SD card (2GB minimum):
```bash
gunzip -c pi-star-*.img.gz | sudo dd of=/dev/sdX bs=4M status=progress
```

### Boot Configuration
Before first boot, create `/boot/pistar-config.txt` on the SD card:

```ini
# Essential Configuration
wifi_ssid=YourWiFiNetwork
wifi_password=YourWiFiPassword
user_password=YourSecurePassword

# Optional Settings
wifi_country=GB
hostname=pi-star
timezone=Europe/London
enable_ssh_password=false
ssh_key=ssh-rsa AAAAB3NzaC1yc2EAAAA... your-email@example.com

# Pi-Star Settings (for future use)
callsign=M0ABC
dmr_id=1234567
```

### First Boot
1. Insert SD card and power on
2. System processes boot configuration automatically
3. Connects to WiFi and sets up user account
4. **Default credentials** (if not configured):
   - Username: `pi-star` (no password set - use SSH keys)
   - Root access: disabled
   - SSH: Key authentication only

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

### System Management
```bash
# Check current partition
cat /boot/ab_state

# Manual partition switching
sudo /usr/local/bin/partition-switcher A  # Switch to partition A
sudo /usr/local/bin/partition-switcher B  # Switch to partition B

# Update system
sudo /usr/local/bin/update-daemon        # Check for updates manually
sudo /usr/local/bin/install-update /path/to/update.tar.gz version

# Boot validation
sudo /usr/local/bin/boot-validator       # Validate current boot
```

### Configuration Management
```bash
# View Pi-Star data structure
ls -la /opt/pistar/
├── config/          # Pi-Star configuration files
├── data/            # Runtime data (logs, database, cache)
├── backup/          # Configuration backups
├── firmware/        # Hardware firmware files
└── www/             # Web interface customizations

# Check boot configuration processing
cat /boot/.config-processed              # Verify config was processed
```

## Development

### Repository Structure
```
├── .github/workflows/    # GitHub Actions CI/CD
├── build/                # Build scripts
├── config/               # System and Pi-Star configurations  
├── scripts/              # OTA update system scripts
├── server/               # GitHub Pages update server
└── keys/                 # Signing keys (GitHub Secrets)
```

### Local Testing
```bash
# Test build scripts
sudo chmod +x build/*.sh
sudo -E ./build/build-rootfs.sh "test-$(date +%s)" "placeholder"

# Validate package
openssl dgst -sha256 -verify public.pem \
  -signature update.tar.gz.sig update.tar.gz
```

### Boot Configuration Development
Test configuration processing:
```bash
# Create test config
echo "hostname=test-pistar" > /boot/pistar-config.txt

# Process manually
sudo /usr/local/bin/process-boot-config

# Check results
hostname  # Should show 'test-pistar'
```

## Security Features

- **RSA-2048 signature verification** on all updates
- **HTTPS transport** via GitHub's infrastructure
- **Atomic updates** prevent corruption
- **Automatic rollback** on boot failure
- **Cryptographically signed** release chain
- **No default passwords** - secure by design
- **SSH key authentication** - password auth disabled by default
- **Passwordless sudo** - streamlined administration

## Update Server

The update system uses GitHub Pages for distribution:
- **Update API**: `https://mw0mwz.github.io/Pi-Star_Alpine_Rolling/latest.json`
- **Manual Downloads**: [GitHub Releases](https://github.com/MW0MWZ/Pi-Star_Alpine_Rolling/releases)
- **Verification**: All packages include cryptographic signatures

## Troubleshooting

### Boot Issues
- **Multiple boot failures**: System automatically rolls back to previous partition
- **Network issues**: Connect via serial console (GPIO pins 14/15)
- **Configuration problems**: Remove `/boot/pistar-config.txt` and reboot with defaults

### Update Issues  
- **Signature verification failed**: Check system time and network connectivity
- **Download failures**: Verify GitHub connectivity and DNS resolution
- **Partition switching**: Check `/boot/ab_state` for current active partition

### Development Issues
- **Build failures**: Check GitHub Actions logs and ensure secrets are configured
- **Missing signatures**: Verify `UPDATE_PRIVATE_KEY` and `UPDATE_PUBLIC_KEY` secrets
- **Environment issues**: Ensure `sudo -E` is used in build scripts

## Support

- **Issues**: [GitHub Issues](https://github.com/MW0MWZ/Pi-Star_Alpine_Rolling/issues)
- **Documentation**: This README and inline code comments
- **Discussions**: [GitHub Discussions](https://github.com/MW0MWZ/Pi-Star_Alpine_Rolling/discussions)

## License

This project is licensed under the GNU General Public License v2.0. See LICENSE file for details.

## Contributing

1. Fork the repository
2. Create feature branch (`git checkout -b feature/amazing-feature`)
3. Test changes with workflow dispatch
4. Submit pull request

### Development Priorities
1. **Pi-Star Integration** - Replace placeholder with actual Pi-Star implementation
2. **Web Configuration Interface** - Browser-based first-boot setup
3. **Hardware Optimization** - Pi-specific performance improvements
4. **Advanced Security** - Hardware security module support

## Acknowledgments

- **Alpine Linux** project for the minimal, secure base OS
- **GitHub** for providing free CI/CD and hosting infrastructure  
- **OpenSSL** project for cryptographic functions
- **Pi-Star** community for the digital radio platform inspiration
- **Andy Taylor (MW0MWZ)** for pioneering a NEW way to Pi-Star!

---

**Ready to revolutionize your Pi-Star experience with modern, reliable, over-the-air updates!** 🚀📡