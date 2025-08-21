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
```

### Command Line Options

- `--size SIZE_GB` - Target image size in GB (default: 5)
- `--url URL` - Custom image URL
- `--mount DIR` - Custom mount directory
- `--verbose` - Enable verbose output
- `--force` - Force re-download of image
- `--skip-chroot` - Skip entering chroot (setup only)
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

## Configuration

Edit the script to customize:

- `$IMAGE_URL` - Source image URL
- `$MOUNT_DIR` - Where to mount the image (default: `/mnt/libre_image`)
- Target size in `grow_image_to_5GB()` function

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

Default image: **Debian 12 Base ARM64** for AML S905X CC
- Source: Libre Computer CI builds
- Architecture: ARM64 (AArch64)
- Base OS: Debian 12 (Bookworm)
- Target Hardware: Amlogic S905X based boards

This script provides a clean, automated way to work with ARM64 SBC images on x86_64 development machines.
