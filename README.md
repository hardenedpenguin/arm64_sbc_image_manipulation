# ARM64 SBC Image Manipulation Tool

A streamlined Perl script for downloading, expanding, and entering a chroot environment for ARM64 Single Board Computer images on x86_64 hosts.

## Features

- **Automatic Download**: Downloads the Debian 12 ARM64 base image from Libre Computer
- **Image Expansion**: Automatically grows the image to 5GB for more space
- **Cross-Architecture Support**: Uses QEMU user emulation for ARM64 chroot on x86_64
- **Smart Partitioning**: Handles both partitioned and unpartitioned images
- **Filesystem Support**: Works with ext4, Btrfs, and XFS filesystems
- **Network Access**: Provides working DNS resolution in chroot environment
- **EFI Support**: Automatically mounts EFI partitions when present
- **Clean Cleanup**: Properly unmounts and restores original state on exit
- **Image Compression**: Optional XZ compression with multiple speed/quality options
- **Checksum Verification**: SHA256 checksum verification for downloaded images
- **Progress Indicators**: Visual progress for downloads, extraction, and compression
- **Dry-Run Mode**: Preview what would be done without executing
- **Logging**: Optional file logging for all operations
- **Status Command**: Check current mounts and loop devices
- **Backup Support**: Create backups before modifying images
- **Resume Downloads**: Automatically resume interrupted downloads
- **Colored Output**: Color-coded output for better readability
- **Fully Configurable**: All hardcoded values can be customized via command-line options

## Prerequisites

Required system tools:
```bash
# Debian/Ubuntu
sudo apt install wget xz-utils parted e2fsprogs btrfs-progs qemu-user-static libdigest-sha-perl

# Optional but recommended for better security
sudo apt install libipc-run3-perl

# Or check if commands exist:
wget xz losetup mount chroot qemu-aarch64-static parted e2fsck resize2fs partprobe btrfs blkid lsblk
```

**Note**: The script works without `IPC::Run3` but uses it when available for better security. `Digest::SHA` is required for checksum verification.

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

# Fast compression
sudo ./sbc_image_manager.pl --compress-fast

# Custom compression level (1-9)
sudo ./sbc_image_manager.pl --compress --compress-level 6

# Compress with custom output name
sudo ./sbc_image_manager.pl --compress --output my_custom_image.xz

# Verify checksum
sudo ./sbc_image_manager.pl --checksum abc123def456...

# Verify checksum from file
sudo ./sbc_image_manager.pl --checksum-file checksums.txt

# Create backup before modification
sudo ./sbc_image_manager.pl --backup

# Dry-run mode (preview without executing)
sudo ./sbc_image_manager.pl --dry-run

# Log to file
sudo ./sbc_image_manager.pl --log /var/log/sbc_image.log

# Show current status
sudo ./sbc_image_manager.pl --status

# Clean up stuck resources
sudo ./sbc_image_manager.pl --cleanup-only

# Combine options: large image with compression and backup
sudo ./sbc_image_manager.pl --size 10 --compress --backup --output large_image.xz

# Full customization example
sudo ./sbc_image_manager.pl \
  --url https://downloads.raspberrypi.org/raspios_lite_arm64/images/raspios_lite_arm64-2023-12-11/2023-12-05-raspios-bookworm-arm64-lite.img.xz \
  --mount /mnt/raspberry_pi \
  --qemu-bin /usr/local/bin/qemu-aarch64-static \
  --image-img raspberry_pi.img \
  --size 8 \
  --verbose \
  --backup \
  --compress-fast
```

### Command Line Options

#### Basic Options
- `--size SIZE_GB` - Target image size in GB (default: 5)
- `--url URL` - Custom image URL
- `--mount DIR` - Custom mount directory (default: `/mnt/libre_image`)
- `--qemu-bin PATH` - Path to qemu-aarch64-static binary (default: `/usr/bin/qemu-aarch64-static`)
- `--image-xz NAME` - Custom .xz filename
- `--image-img NAME` - Custom .img filename
- `--verbose` - Enable verbose output
- `--force` - Force re-download of image
- `--skip-chroot` - Skip entering chroot (setup only)
- `--no-resume` - Disable resume of interrupted downloads
- `--help` - Show help message

#### Compression Options
- `--compress` - Compress image with best XZ compression after cleanup (level 9 with -e)
- `--compress-fast` - Use fast compression (level 1)
- `--compress-level N` - Use compression level 1-9 (default: 9)
- `--output NAME` - Output filename for compressed image (default: auto-generated)

#### Security & Verification
- `--checksum HASH` - Verify image SHA256 checksum
- `--checksum-file FILE` - Read checksums from file (format: `hash filename`)

#### Safety & Utilities
- `--backup` - Create backup of image before modification
- `--dry-run` - Show what would be done without executing
- `--log FILE` - Log all operations to file
- `--status` - Show current status (mounts, loop devices, image info)
- `--cleanup-only` - Clean up existing mounts and loop devices, then exit

### Exit Codes

The script uses the following exit codes:
- `0` - Success
- `1` - General error
- `2` - Missing dependencies
- `3` - Invalid arguments
- `4` - Not running as root (required for most operations)

### What it does:

1. **Validates** command line options and dependencies
2. **Checks** for root privileges (unless using --status or --dry-run)
3. **Checks** for existing work (resume capability)
4. **Downloads** the Debian 12 ARM64 image (if not already present, with resume support)
5. **Verifies** checksum if provided
6. **Validates** image integrity and size
7. **Extracts** the compressed image (with progress indication)
8. **Creates backup** if requested
9. **Expands** the image to specified size (default: 5GB)
10. **Mounts** the image with proper loop device setup
11. **Detects and resizes** filesystem (ext4, Btrfs, XFS support)
12. **Sets up** QEMU emulation for cross-architecture support
13. **Mounts** necessary bind mounts (dev, proc, sys, etc.)
14. **Enters** an interactive ARM64 chroot environment (unless --skip-chroot)
15. **Cleans up** mounts and loop devices on exit
16. **Compresses** the modified image with XZ compression (if --compress specified)

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

After making modifications to the image, you can optionally compress it using XZ compression with various quality/speed options:

### Benefits of Compression:
- **Reduced file size**: Typically 60-80% smaller than uncompressed images
- **Faster transfer**: Smaller files transfer faster over networks
- **Storage efficiency**: Save disk space when storing multiple images
- **Distribution ready**: Compressed images are ideal for sharing

### Compression Modes:
- **Best compression** (`--compress`): Uses `xz -9 -e` for maximum compression ratio (slowest)
- **Fast compression** (`--compress-fast`): Uses `xz -1` for quick compression (fastest)
- **Custom level** (`--compress-level N`): Use level 1-9 (1=fast, 9=best)

### Compression Examples:
```bash
# Basic compression with auto-generated name (best quality)
sudo ./sbc_image_manager.pl --compress
# Output: debian-12-base-arm64+aml-s905x-cc_compressed.xz

# Fast compression
sudo ./sbc_image_manager.pl --compress-fast

# Custom compression level
sudo ./sbc_image_manager.pl --compress --compress-level 6

# Custom output name
sudo ./sbc_image_manager.pl --compress --output my_custom_image.xz

# Large image with compression
sudo ./sbc_image_manager.pl --size 10 --compress --output large_image.xz
```

**Note**: Compression can take a significant amount of time for large images, especially with the best compression settings. The script will show progress information during the process.

## Checksum Verification

Verify the integrity of downloaded images using SHA256 checksums:

```bash
# Verify with inline checksum
sudo ./sbc_image_manager.pl --checksum abc123def4567890...

# Verify from checksum file (format: hash filename)
sudo ./sbc_image_manager.pl --checksum-file checksums.txt
```

Example checksum file format:
```
abc123def4567890...  debian-12-base-arm64+aml-s905x-cc.img.xz
def456abc1237890...  raspberry_pi.img.xz
```

If checksum verification fails, the script will abort and remove the corrupted download.

## Dry-Run Mode

Preview what the script would do without actually executing any commands:

```bash
sudo ./sbc_image_manager.pl --dry-run
```

This is useful for:
- Testing command-line options
- Understanding what operations would be performed
- Debugging configuration issues

## Status Command

Check the current state of mounts, loop devices, and image files:

```bash
sudo ./sbc_image_manager.pl --status
```

This shows:
- Currently mounted directories
- Active loop devices
- Existing image files and their sizes

No root privileges required for status checks.

## Cleanup-Only Mode

Clean up stuck resources (mounts and loop devices) without running the full script:

```bash
sudo ./sbc_image_manager.pl --cleanup-only
```

Useful when:
- Previous run was interrupted
- Mounts or loop devices are stuck
- Manual cleanup is needed

## Logging

Log all operations to a file for debugging or auditing:

```bash
sudo ./sbc_image_manager.pl --log /var/log/sbc_image.log
```

Log entries include:
- Timestamps
- Log levels (info, warn, error, success, debug)
- All operations performed
- Error messages

## Configuration

All configuration is done via command-line options. No need to edit the script!

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

- **Root Check**: Validates root privileges before operations (except status/dry-run)
- **Signal Handling**: Ctrl+C properly cleans up mounts and loop devices
- **Safe Cleanup**: Enhanced error handling during cleanup operations
- **Automatic Cleanup**: Unmounts everything and restores original state
- **Enhanced Resolv.conf Handling**: Preserves and restores original DNS configuration (symlink, file, or none)
- **Loop Device Management**: Prevents conflicts with existing loop devices
- **Image Validation**: Checks file integrity and minimum size requirements
- **Resume Capability**: Skips re-downloading existing images, resumes interrupted downloads
- **Path Validation**: Validates paths to prevent injection attacks
- **Shell Injection Protection**: Uses safe command execution methods
- **Enhanced Error Handling**: Better error messages and recovery
- **Checksum Verification**: Optional SHA256 verification for downloads

## Security Improvements

The script includes several security enhancements:

- **Command Injection Protection**: Uses safe command execution with proper escaping
- **Path Validation**: Validates all user-provided paths
- **IPC::Run3 Support**: Uses secure command execution when available
- **Input Sanitization**: Validates and sanitizes all command-line arguments

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

## Troubleshooting

### Stuck Mounts or Loop Devices

If mounts or loop devices are stuck from a previous run:

```bash
sudo ./sbc_image_manager.pl --cleanup-only
```

### Check Current Status

See what's currently mounted or active:

```bash
sudo ./sbc_image_manager.pl --status
```

### Permission Errors

Most operations require root privileges. Ensure you're running with `sudo`:

```bash
sudo ./sbc_image_manager.pl
```

### Download Failures

If downloads fail:
- Check your internet connection
- Verify the URL is accessible
- Use `--no-resume` to disable resume if causing issues
- Check disk space availability

### Compression Takes Too Long

Use faster compression for large images:

```bash
sudo ./sbc_image_manager.pl --compress-fast
```

Or use a custom level:

```bash
sudo ./sbc_image_manager.pl --compress --compress-level 3
```

## Examples

### Complete Workflow

```bash
# Download, modify, and compress an image
sudo ./sbc_image_manager.pl \
  --size 8 \
  --backup \
  --compress \
  --compress-level 6 \
  --log /var/log/image_build.log

# Inside chroot:
apt update
apt install -y openssh-server vim
systemctl enable ssh
exit

# Image is automatically compressed after exit
```

### Batch Processing Multiple Images

```bash
# Process multiple images
for img in raspberry_pi raspberry_pi_full ubuntu_server; do
  sudo ./sbc_image_manager.pl \
    --url "https://example.com/${img}.img.xz" \
    --image-img "${img}.img" \
    --mount "/mnt/${img}" \
    --compress-fast \
    --output "${img}_compressed.xz"
done
```

This script provides a clean, automated way to work with ARM64 SBC images on x86_64 development machines, with full customization support for different images and configurations.
