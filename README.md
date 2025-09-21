# ARM64 SBC Image Manipulation Tool

A streamlined Perl script for downloading, expanding, and entering a chroot environment for ARM64 Single Board Computer images on x86_64 hosts.

## Features

- **Automatic Download**: Downloads the Debian 12 ARM64 base image from Libre Computer
- **Image Expansion**: Automatically grows the image to 5GB for more space
- **Cross-Architecture Support**: Uses QEMU user emulation for ARM64 chroot on x86_64
- **Smart Partitioning**: Handles both partitioned and unpartitioned images
- **Filesystem Support**: Works with ext4 and Btrfs filesystems
- **Network Access**: Provides working DNS resolution in chroot environment
- **EFI Support**: Automatically mounts EFI partitions when present
- **Clean Cleanup**: Properly unmounts and restores original state on exit
- **Image Compression**: Optional best-quality XZ compression after modifications
- **Fully Configurable**: All hardcoded values can be customized via command-line options

## Prerequisites

Required system tools:
```bash
# Debian/Ubuntu
sudo apt install wget xz-utils parted e2fsprogs btrfs-progs qemu-user-static

# Or check if commands exist:
wget xz losetup mount chroot qemu-aarch64-static parted e2fsck resize2fs partprobe btrfs blkid lsblk
```

## Usage

Run the script as root with various options:

```bash
# Basic usage (defaults)
sudo ./sbc_image_manager.pl

# Create larger image (10GB)
sudo ./sbc_image_manager.pl --size 10

# Use custom image URL
sudo ./sbc_image_manager.pl --url https://example.com/custom-image.img.xz

# Enable verbose output
sudo ./sbc_image_manager.pl --verbose

# Force re-download existing image
sudo ./sbc_image_manager.pl --force

# Setup only (skip chroot)
sudo ./sbc_image_manager.pl --skip-chroot

# Custom mount directory
sudo ./sbc_image_manager.pl --mount /mnt/custom

# Custom QEMU binary path
sudo ./sbc_image_manager.pl --qemu-bin /usr/local/bin/qemu-aarch64-static

# Custom image filenames
sudo ./sbc_image_manager.pl --image-img my_custom.img --image-xz my_custom.img.xz

# Compress image after modifications
sudo ./sbc_image_manager.pl --compress

# Compress with custom output name
sudo ./sbc_image_manager.pl --compress --output my_custom_image.xz

# Combine options: large image with compression
sudo ./sbc_image_manager.pl --size 10 --compress --output large_image.xz

# Full customization example
sudo ./sbc_image_manager.pl \
  --url https://downloads.raspberrypi.org/raspios_lite_arm64/images/raspios_lite_arm64-2023-12-11/2023-12-05-raspios-bookworm-arm64-lite.img.xz \
  --mount /mnt/raspberry_pi \
  --qemu-bin /usr/local/bin/qemu-aarch64-static \
  --image-img raspberry_pi.img \
  --size 8 \
  --verbose
```

### Command Line Options

- `--size SIZE_GB` - Target image size in GB (default: 5)
- `--url URL` - Custom image URL
- `--mount DIR` - Custom mount directory (default: `/mnt/libre_image`)
- `--qemu-bin PATH` - Path to qemu-aarch64-static binary (default: `/usr/bin/qemu-aarch64-static`)
- `--image-xz NAME` - Custom .xz filename (default: `debian-12-base-arm64+aml-s905x-cc.img.xz`)
- `--image-img NAME` - Custom .img filename (default: `debian-12-base-arm64+aml-s905x-cc.img`)
- `--verbose` - Enable verbose output
- `--force` - Force re-download of image
- `--skip-chroot` - Skip entering chroot (setup only)
- `--compress` - Compress image with best XZ compression after cleanup
- `--output NAME` - Output filename for compressed image (default: auto-generated)
- `--help` - Show help message

### What it does:

1. **Validates** command line options and dependencies
2. **Checks** for existing work (resume capability)
3. **Downloads** the Debian 12 ARM64 image (if not already present)
4. **Validates** image integrity and size
5. **Extracts** the compressed image
6. **Expands** the image to specified size (default: 5GB)
7. **Mounts** the image with proper loop device setup
8. **Detects and resizes** filesystem (ext4, Btrfs, XFS support)
9. **Sets up** QEMU emulation for cross-architecture support
10. **Mounts** necessary bind mounts (dev, proc, sys, etc.)
11. **Enters** an interactive ARM64 chroot environment (unless --skip-chroot)
12. **Cleans up** mounts and loop devices on exit
13. **Compresses** the modified image with best XZ compression (if --compress specified)

### In the chroot environment:

You can run any ARM64 commands as if you were on native ARM64 hardware:

```bash
# Update package lists
apt update

# Install packages
apt install vim htop curl

# Create users
adduser myuser

# Configure services
systemctl enable ssh
```

Press `Ctrl+D` or type `exit` to leave the chroot and automatically clean up.

## Image Compression

After making modifications to the image, you can optionally compress it using the best XZ compression available:

### Benefits of Compression:
- **Reduced file size**: Typically 60-80% smaller than uncompressed images
- **Faster transfer**: Smaller files transfer faster over networks
- **Storage efficiency**: Save disk space when storing multiple images
- **Distribution ready**: Compressed images are ideal for sharing

### Compression Options:
- **Best compression**: Uses `xz -9 -e` for maximum compression ratio
- **Auto-naming**: Automatically generates output filename if not specified
- **Integrity verification**: Verifies compressed file integrity after compression
- **Progress feedback**: Shows original size, compressed size, and compression ratio

### Compression Examples:
```bash
# Basic compression with auto-generated name
sudo ./sbc_image_manager.pl --compress
# Output: debian-12-base-arm64+aml-s905x-cc_compressed.xz

# Custom output name
sudo ./sbc_image_manager.pl --compress --output my_custom_image.xz

# Large image with compression
sudo ./sbc_image_manager.pl --size 10 --compress --output large_image.xz
```

**Note**: Compression can take a significant amount of time for large images, especially with the best compression settings. The script will show progress information during the process.

## Configuration

All configuration is now done via command-line options. No need to edit the script!

### Default Values

The script uses these defaults, which can be overridden with command-line options:

- **Image URL**: `https://distro.libre.computer/ci/debian/12/debian-12-base-arm64%2Baml-s905x-cc.img.xz`
- **Mount Directory**: `/mnt/libre_image`
- **QEMU Binary**: `/usr/bin/qemu-aarch64-static`
- **Image Size**: `5GB`
- **Image Files**: `debian-12-base-arm64+aml-s905x-cc.img.xz` → `debian-12-base-arm64+aml-s905x-cc.img`

### Customization Examples

```bash
# Use different SBC image (Raspberry Pi)
sudo ./sbc_image_manager.pl \
  --url https://downloads.raspberrypi.org/raspios_lite_arm64/images/raspios_lite_arm64-2023-12-11/2023-12-05-raspios-bookworm-arm64-lite.img.xz \
  --image-img raspberry_pi.img \
  --mount /mnt/raspberry_pi

# Use custom QEMU installation
sudo ./sbc_image_manager.pl \
  --qemu-bin /usr/local/bin/qemu-aarch64-static \
  --mount /tmp/custom_mount

# Work with multiple images simultaneously
sudo ./sbc_image_manager.pl --image-img image1.img --mount /mnt/image1
sudo ./sbc_image_manager.pl --image-img image2.img --mount /mnt/image2
```

## Safety Features

- **Signal Handling**: Ctrl+C properly cleans up mounts and loop devices
- **Safe Cleanup**: Enhanced error handling during cleanup operations
- **Automatic Cleanup**: Unmounts everything and restores original state
- **Enhanced Resolv.conf Handling**: Preserves and restores original DNS configuration (symlink, file, or none)
- **Loop Device Management**: Prevents conflicts with existing loop devices
- **Image Validation**: Checks file integrity and minimum size requirements
- **Resume Capability**: Skips re-downloading existing images
- **Enhanced Error Handling**: Better error messages and recovery

## Image Details

### Default Image: **Debian 12 Base ARM64** for AML S905X CC
- Source: Libre Computer CI builds
- Architecture: ARM64 (AArch64)
- Base OS: Debian 12 (Bookworm)
- Target Hardware: Amlogic S905X based boards

### Supported Images

The script can work with any ARM64 image that meets these requirements:
- **Format**: Raw disk image (.img) or compressed (.img.xz)
- **Architecture**: ARM64 (AArch64)
- **Filesystem**: ext4, Btrfs, or XFS
- **Partitioning**: Both partitioned and unpartitioned images supported

### Popular ARM64 SBC Images

- **Raspberry Pi OS**: `https://downloads.raspberrypi.org/raspios_lite_arm64/images/`
- **Ubuntu for ARM64**: `https://cdimage.ubuntu.com/releases/`
- **Debian ARM64**: `https://cdimage.debian.org/cdimage/`
- **Libre Computer**: `https://distro.libre.computer/ci/`

This script provides a clean, automated way to work with ARM64 SBC images on x86_64 development machines, with full customization support for different images and configurations.
