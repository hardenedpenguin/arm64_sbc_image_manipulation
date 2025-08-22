#!/usr/bin/env perl
use strict;
use warnings;
use File::Path qw(make_path);
use File::Copy;
use Cwd qw(abs_path);
use Getopt::Long;

# === Configuration ===
my $IMAGE_URL  = "https://distro.libre.computer/ci/debian/12/debian-12-base-arm64%2Baml-s905x-cc.img.xz";
my $IMAGE_XZ   = "debian-12-base-arm64+aml-s905x-cc.img.xz";
my $IMAGE_IMG  = "debian-12-base-arm64+aml-s905x-cc.img";
my $MOUNT_DIR  = "/mnt/libre_image";
my $QEMU_BIN   = "/usr/bin/qemu-aarch64-static";

# === Command Line Options ===
my $IMAGE_SIZE_GB = 5;
my $CUSTOM_IMAGE_URL;
my $CUSTOM_MOUNT_DIR;
my $VERBOSE = 0;
my $FORCE_DOWNLOAD = 0;
my $SKIP_CHROOT = 0;
my $COMPRESS_IMAGE = 0;
my $OUTPUT_NAME;

my $LOOP_DEV;
my $PARTITION;
my $EFI_PARTITION;
my $RESOLV_CONF_SYMLINK_TARGET; # To store original symlink target
my $RESOLV_CONF_ORIGINAL_TYPE;  # 'symlink', 'file', or 'none'
my $RESOLV_CONF_BACKUP_FILE;    # Backup file path for resolv.conf content

# === Helper Functions ===
sub show_help {
    print <<EOF;
ARM64 SBC Image Manager

Usage: $0 [OPTIONS]

Options:
  --size SIZE_GB        Target image size in GB (default: 5)
  --url URL            Custom image URL
  --mount DIR          Custom mount directory
  --verbose            Enable verbose output
  --force              Force re-download of image
  --skip-chroot        Skip entering chroot (setup only)
  --compress           Compress image with best XZ compression after cleanup
  --output NAME        Output filename for compressed image (default: auto-generated)
  --help               Show this help message

Examples:
  $0                    # Use defaults
  $0 --size 10         # Create 10GB image
  $0 --url https://... # Use custom image URL
  $0 --verbose         # Enable verbose output
  $0 --force           # Re-download existing image
  $0 --compress        # Compress image after cleanup
  $0 --compress --output my_image.xz  # Custom output name

EOF
    exit 0;
}

sub run_or_die {
    my ($cmd) = @_;
    print "[*] Running: $cmd\n" if $VERBOSE;
    my $output = system($cmd);
    if ($output != 0) {
        my $exit_code = $output >> 8;
        print "[!] Command failed (exit $exit_code): $cmd\n";
        die "Aborting due to command failure\n";
    }
}

sub run_capture {
    my ($cmd) = @_;
    my $output = `$cmd`;
    chomp($output);
    return $output;
}

sub command_exists {
    my ($cmd) = @_;
    return system("command -v $cmd >/dev/null 2>&1") == 0;
}

sub is_mountpoint {
    my ($path) = @_;
    # Check if path exists before checking if it's a mountpoint to avoid warnings
    return -e $path && system("mountpoint -q $path") == 0;
}

sub safe_cleanup {
    eval { cleanup(); };
    if ($@) {
        print "[!] Error during cleanup: $@\n";
        # Force cleanup of critical resources
        system("umount -lf $MOUNT_DIR 2>/dev/null");
        system("losetup -d $LOOP_DEV 2>/dev/null") if $LOOP_DEV;
    }
}

sub cleanup {
    print "[*] Starting cleanup...\n";

    # Unmount EFI first
    if ($MOUNT_DIR && -d "$MOUNT_DIR/boot/efi" && is_mountpoint("$MOUNT_DIR/boot/efi")) {
        run_or_die("umount -lf $MOUNT_DIR/boot/efi");
    }

    # Unmount all the bind mounts
    my @bind_dirs = ("/etc/resolv.conf", "/run", "/sys", "/proc", "/dev/pts", "/dev");
    foreach my $dir (@bind_dirs) {
        my $target = "$MOUNT_DIR$dir";
        run_or_die("umount -lf $target") if is_mountpoint($target);
    }

    # Restore resolv.conf state BEFORE unmounting the root filesystem
    if ($MOUNT_DIR && is_mountpoint($MOUNT_DIR)) {
        my $chroot_resolv_path = "$MOUNT_DIR/etc/resolv.conf";
        
        # Remove the bind mount point (file) that was created
        unlink($chroot_resolv_path);
        
        if (defined $RESOLV_CONF_ORIGINAL_TYPE) {
            if ($RESOLV_CONF_ORIGINAL_TYPE eq 'symlink' && defined $RESOLV_CONF_SYMLINK_TARGET) {
                print "[*] Restoring resolv.conf symlink...\n";
                if (symlink($RESOLV_CONF_SYMLINK_TARGET, $chroot_resolv_path)) {
                    print "[*] Successfully restored resolv.conf symlink to '$RESOLV_CONF_SYMLINK_TARGET'.\n";
                } else {
                    warn "[!] WARNING: Failed to restore resolv.conf symlink: $!\n";
                }
            } elsif ($RESOLV_CONF_ORIGINAL_TYPE eq 'file' && -f $RESOLV_CONF_BACKUP_FILE) {
                print "[*] Restoring resolv.conf file...\n";
                if (copy($RESOLV_CONF_BACKUP_FILE, $chroot_resolv_path)) {
                    print "[*] Successfully restored resolv.conf file.\n";
                    unlink($RESOLV_CONF_BACKUP_FILE);  # Clean up backup
                } else {
                    warn "[!] WARNING: Failed to restore resolv.conf file: $!\n";
                }
            } elsif ($RESOLV_CONF_ORIGINAL_TYPE eq 'none') {
                print "[*] Creating default resolv.conf symlink...\n";
                if (symlink("/run/systemd/resolve/stub-resolv.conf", $chroot_resolv_path)) {
                    print "[*] Created default resolv.conf symlink.\n";
                } else {
                    warn "[!] WARNING: Failed to create default resolv.conf symlink: $!\n";
                }
            }
        }
    }

    # Now unmount the main mount point
    run_or_die("umount -lf $MOUNT_DIR") if is_mountpoint($MOUNT_DIR);

    # Finally, detach the loop device
    run_or_die("losetup -d $LOOP_DEV") if $LOOP_DEV && system("losetup $LOOP_DEV >/dev/null 2>&1") == 0;

    print "[*] Cleanup complete.\n";
}


sub validate_image {
    my ($image_path) = @_;
    
    print "[*] Validating image integrity...\n";
    
    # Check if file exists
    unless (-f $image_path) {
        die "[!] Image file not found: $image_path\n";
    }
    
    # Check if it's a valid disk image
    my $file_type = `file $image_path`;
    unless ($file_type =~ /DOS\/MBR boot sector|Linux.*filesystem|data/) {
        print "[!] Warning: Unexpected file type: $file_type\n";
        print "[*] Continuing anyway...\n";
    }
    
    # Check for minimum size
    my $size = (stat($image_path))[7];
    if ($size < 100 * 1024 * 1024) {  # 100MB minimum
        die "[!] Image file too small ($size bytes)\n";
    }
    
    print "[✓] Image validation passed\n";
}

sub check_existing_work {
    if (-f $IMAGE_IMG) {
        print "[*] Found existing image: $IMAGE_IMG\n";
        unless ($FORCE_DOWNLOAD) {
            print "[*] Use --force to re-download\n";
            return 1;
        }
    }
    return 0;
}

sub grow_image {
    print "[*] Checking image size...\n";
    my $size = (stat($IMAGE_IMG))[7];
    my $target = $IMAGE_SIZE_GB * 1024 * 1024 * 1024;

    if ($size >= $target) {
        print "[*] Image is already >= ${IMAGE_SIZE_GB}GB, skipping resize.\n";
        return;
    }

    print "[*] Growing image file to ${IMAGE_SIZE_GB}GB...\n";
    run_or_die("truncate -s ${IMAGE_SIZE_GB}G $IMAGE_IMG");

    my $loopdev = run_capture("losetup --show -Pf $IMAGE_IMG");
    die "[!] Failed to setup loop device.\n" unless $loopdev;

    my $sector_size = run_capture("blockdev --getss $loopdev");
    my $disk_sectors = run_capture("blockdev --getsz $loopdev");

    print "[*] Disk size: ", $disk_sectors * $sector_size / 1024 / 1024, "MB\n";

    my @part_lines = grep { !/^BYT/ && !/^\/dev/ } `parted -ms $loopdev unit s print`;
    die "[!] No partitions found.\n" unless @part_lines;

    my ($root_num, $root_start, $root_end, $root_fs);
    my $max_size = 0;

    foreach my $line (@part_lines) {
        chomp($line);
        my ($num, $start, $end, $fs, @rest) = split(':', $line);
        $start =~ s/s$//;
        $end =~ s/s$//;

        if ($fs eq "ext4" || $fs eq "btrfs") {
            ($root_num, $root_start, $root_end, $root_fs) = ($num, $start, $end, $fs);
            last;
        }

        my $size = $end - $start;
        if ($size > $max_size) {
            ($root_num, $root_start, $root_end, $root_fs) = ($num, $start, $end, $fs);
            $max_size = $size;
        }
    }

    die "[!] Failed to determine root partition.\n" unless $root_num;

    my $next_start = $disk_sectors;
    foreach my $line (@part_lines) {
        chomp($line);
        my ($num, $start, $end, $fs, @rest) = split(':', $line);
        $start =~ s/s$//;

        if ($num > $root_num && $start < $next_start) {
            $next_start = $start;
        }
    }

    my $new_end_sector = $next_start - 1;
    die "[!] No space to expand root partition.\n" if $new_end_sector <= $root_start;

    my $new_end_mb = int($new_end_sector * $sector_size / 1024 / 1024);
    print "[*] Resizing partition $root_num to ~${new_end_mb}MB...\n";
    run_or_die("parted -s $loopdev resizepart $root_num ${new_end_mb}MB");

    run_or_die("partprobe $loopdev");
    sleep(1);
    run_or_die("losetup -d $loopdev");
}

sub format_size {
    my ($bytes) = @_;
    my @units = qw(B KB MB GB);
    my $unit = 0;
    my $size = $bytes;
    
    while ($size >= 1024 && $unit < $#units) {
        $size /= 1024;
        $unit++;
    }
    
    return sprintf("%.1f %s", $size, $units[$unit]);
}

sub compress_image {
    my ($input_image, $output_name) = @_;
    
    # Check if input image exists
    unless (-f $input_image) {
        die "[!] Input image not found: $input_image\n";
    }
    
    # Generate output name if not provided
    if (!$output_name) {
        my ($name, $ext) = $input_image =~ /(.+)\.(.+)$/;
        $output_name = "${name}_compressed.xz";
    }
    
    # Ensure .xz extension
    $output_name .= ".xz" unless $output_name =~ /\.xz$/;
    
    # Check if output file already exists
    if (-f $output_name) {
        print "[!] Warning: Output file already exists: $output_name\n";
        print "[*] Overwriting existing file...\n";
    }
    
    print "[*] Compressing image with best XZ compression...\n";
    print "[*] This may take a while depending on image size...\n";
    
    # Get original file size for progress indication
    my $original_size = (stat($input_image))[7];
    print "[*] Original image size: " . format_size($original_size) . "\n";
    
    # Use xz with best compression (-9) and extreme preset (-e)
    # -c outputs to stdout, which we redirect to the output file
    run_or_die("xz -9 -e -c '$input_image' > '$output_name'");
    
    # Show compression results
    my $compressed_size = (stat($output_name))[7];
    my $compression_ratio = sprintf("%.1f", (1 - $compressed_size / $original_size) * 100);
    
    print "[✓] Compression complete!\n";
    print "[*] Original size: " . format_size($original_size) . "\n";
    print "[*] Compressed size: " . format_size($compressed_size) . "\n";
    print "[*] Compression ratio: ${compression_ratio}%\n";
    print "[*] Output file: $output_name\n";
    
    # Verify the compressed file
    print "[*] Verifying compressed image integrity...\n";
    run_or_die("xz -t '$output_name'");
    print "[✓] Compressed image verification passed\n";
}

# === Main Logic ===
$SIG{INT} = $SIG{TERM} = sub { safe_cleanup(); exit 1 };

# Parse command line arguments
GetOptions(
    "size=i" => \$IMAGE_SIZE_GB,
    "url=s" => \$CUSTOM_IMAGE_URL,
    "mount=s" => \$CUSTOM_MOUNT_DIR,
    "verbose" => \$VERBOSE,
    "force" => \$FORCE_DOWNLOAD,
    "skip-chroot" => \$SKIP_CHROOT,
    "compress" => \$COMPRESS_IMAGE,
    "output=s" => \$OUTPUT_NAME,
    "help" => \&show_help,
);

# Use custom values if provided
$IMAGE_URL = $CUSTOM_IMAGE_URL if $CUSTOM_IMAGE_URL;
$MOUNT_DIR = $CUSTOM_MOUNT_DIR if $CUSTOM_MOUNT_DIR;

print "[*] ARM64 SBC Image Manager\n";
print "[*] Target size: ${IMAGE_SIZE_GB}GB\n";
print "[*] Mount directory: $MOUNT_DIR\n";
print "[*] Image URL: $IMAGE_URL\n";
print "[*] Verbose mode: " . ($VERBOSE ? "enabled" : "disabled") . "\n";
print "[*] Compression mode: " . ($COMPRESS_IMAGE ? "enabled" : "disabled") . "\n";
if ($COMPRESS_IMAGE && $OUTPUT_NAME) {
    print "[*] Output file: $OUTPUT_NAME\n";
}
print "\n";

foreach my $cmd (qw/wget xz losetup mount chroot qemu-aarch64-static parted e2fsck resize2fs partprobe btrfs blkid lsblk/) {
    die "[!] Missing required command: $cmd\n" unless command_exists($cmd);
}

die "[!] $QEMU_BIN not found\n" unless -x $QEMU_BIN;
make_path($MOUNT_DIR);

print "[*] Cleaning up previous state...\n";
my @old_loops = `losetup -a | grep $IMAGE_IMG | cut -d: -f1`;
chomp(@old_loops);
foreach my $dev (@old_loops) {
    run_or_die("losetup -d $dev");
}

# Check for existing work
unless (check_existing_work()) {
    print "[*] Downloading image...\n";
    run_or_die("wget -O $IMAGE_XZ $IMAGE_URL");
    print "[*] Extracting image...\n";
    run_or_die("xz -dk $IMAGE_XZ");
}

# Validate the image
validate_image($IMAGE_IMG);

grow_image();

print "[*] Attaching image to loop device...\n";
$LOOP_DEV = run_capture("losetup --show -Pf $IMAGE_IMG");
die "[!] Failed to setup loop device.\n" unless $LOOP_DEV;

my @partitions = grep { /part/ } `lsblk -lnp -o NAME,TYPE $LOOP_DEV`;
if (@partitions) {
    print "[*] Partitioned image detected.\n";
    my @sizes = `lsblk -lnp -o NAME,SIZE,TYPE $LOOP_DEV | awk '\$3==\"part\" {print \$1,\$2}' | sort -k2 -h`;
    ($PARTITION) = split(' ', $sizes[-1]);
} else {
    print "[*] Unpartitioned image detected.\n";
    $PARTITION = $LOOP_DEV;
}

die "[!] Failed to detect root partition.\n" unless $PARTITION;

print "[*] Using root partition: $PARTITION\n";
run_or_die("mount $PARTITION $MOUNT_DIR");

# === Filesystem Resize ===
sub detect_and_resize_fs {
    my ($partition) = @_;
    
    my $fs_type = run_capture("blkid -o value -s TYPE $partition");
    print "[*] Detected filesystem: $fs_type\n";
    
    if ($fs_type eq "ext4") {
        print "[*] Resizing ext4 filesystem...\n";
        run_or_die("e2fsck -f -y $partition");
        run_or_die("resize2fs $partition");
    } elsif ($fs_type eq "btrfs") {
        print "[*] Resizing Btrfs filesystem...\n";
        run_or_die("btrfs filesystem resize max $MOUNT_DIR");
    } elsif ($fs_type eq "xfs") {
        print "[*] XFS detected - manual resize may be needed\n";
        print "[!] XFS requires offline resize. Consider using a larger image.\n";
    } elsif ($fs_type eq "vfat" || $fs_type eq "fat32") {
        print "[*] FAT filesystem detected - skipping resize\n";
    } else {
        print "[!] Unknown filesystem type: $fs_type\n";
        print "[*] Skipping filesystem resize\n";
    }
}

detect_and_resize_fs($PARTITION);

# === Sanity Check ===
unless (-d "$MOUNT_DIR/etc") {
    print "[!] /etc directory not found after mounting root filesystem.\n";
    print "[!] Likely indicates an empty or improperly configured image.\n";
    cleanup();
    exit 1;
}

# === Handle resolv.conf state preservation ===
my $chroot_resolv_path = "$MOUNT_DIR/etc/resolv.conf";
$RESOLV_CONF_BACKUP_FILE = "/tmp/resolv_conf_backup_$$";

# Determine the original state and preserve it
if (-l $chroot_resolv_path) {
    # It's a symlink - save the target
    $RESOLV_CONF_ORIGINAL_TYPE = 'symlink';
    $RESOLV_CONF_SYMLINK_TARGET = readlink($chroot_resolv_path);
    die "[!] Failed to read resolv.conf symlink" unless defined $RESOLV_CONF_SYMLINK_TARGET;
    print "[*] Found resolv.conf symlink to '$RESOLV_CONF_SYMLINK_TARGET'. Storing for restoration.\n";
} elsif (-f $chroot_resolv_path) {
    # It's a regular file - backup the content
    $RESOLV_CONF_ORIGINAL_TYPE = 'file';
    run_or_die("cp '$chroot_resolv_path' '$RESOLV_CONF_BACKUP_FILE'");
    print "[*] Found resolv.conf file. Backed up content for restoration.\n";
} else {
    # File doesn't exist
    $RESOLV_CONF_ORIGINAL_TYPE = 'none';
    print "[*] No resolv.conf found in image. Will create symlink on cleanup.\n";
}

# Remove the original to prepare for bind mount
if (-e $chroot_resolv_path || -l $chroot_resolv_path) {
    print "[*] Temporarily removing existing $chroot_resolv_path for chroot networking.\n";
    unlink($chroot_resolv_path) or die "[!] Failed to remove existing resolv.conf: $!\n";
}

# Create an empty file to act as the mount point
print "[*] Creating temporary mount point for /etc/resolv.conf.\n";
run_or_die("touch $chroot_resolv_path");


# === EFI Mount if present ===
if (@partitions) {
    my $efi_line = run_capture("lsblk -lnp $LOOP_DEV -o NAME,FSTYPE | grep -i 'vfat' | awk '{print \$1}'");
    if ($efi_line) {
        $EFI_PARTITION = $efi_line;
        run_or_die("mkdir -p $MOUNT_DIR/boot/efi");
        run_or_die("mount $EFI_PARTITION $MOUNT_DIR/boot/efi");
    }
}

# === Bind Mounts ===
my @binds = ("/dev", "/dev/pts", "/proc", "/sys", "/run");
foreach my $dir (@binds) {
    run_or_die("mount --bind $dir $MOUNT_DIR$dir");
}
run_or_die("mount --bind /etc/resolv.conf $MOUNT_DIR/etc/resolv.conf");
run_or_die("cp $QEMU_BIN $MOUNT_DIR/usr/bin/");

if ($SKIP_CHROOT) {
    print "[*] Skipping chroot (setup only mode)\n";
    print "[*] Image is mounted at: $MOUNT_DIR\n";
    print "[*] Run cleanup manually when done\n";
} else {
    print "\n[*] Entering ARM64 chroot...\n";
    system("chroot $MOUNT_DIR /usr/bin/qemu-aarch64-static /bin/bash");
}

cleanup();

# Compress image if requested
if ($COMPRESS_IMAGE) {
    print "\n[*] Starting image compression...\n";
    compress_image($IMAGE_IMG, $OUTPUT_NAME);
}

print "[✓] Done. Image is unmounted and clean.\n";
