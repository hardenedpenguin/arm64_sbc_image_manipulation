#!/usr/bin/env perl
use strict;
use warnings;
use File::Path qw(make_path);
use File::Copy;
use Cwd qw(abs_path);
use Getopt::Long;
use POSIX qw(strftime);
use Digest::SHA qw(sha256_hex);
eval { require IPC::Run3; };
my $HAS_IPC_RUN3 = $@ ? 0 : 1;

# === Constants ===
use constant {
    MIN_IMAGE_SIZE => 100 * 1024 * 1024,  # 100MB minimum
    EXIT_SUCCESS => 0,
    EXIT_GENERAL_ERROR => 1,
    EXIT_MISSING_DEPS => 2,
    EXIT_INVALID_ARGS => 3,
    EXIT_NOT_ROOT => 4,
};

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
my $CUSTOM_QEMU_BIN;
my $CUSTOM_IMAGE_XZ;
my $CUSTOM_IMAGE_IMG;
my $VERBOSE = 0;
my $FORCE_DOWNLOAD = 0;
my $SKIP_CHROOT = 0;
my $COMPRESS_IMAGE = 0;
my $OUTPUT_NAME;
my $DRY_RUN = 0;
my $CHECKSUM;
my $CHECKSUM_FILE;
my $BACKUP_IMAGE = 0;
my $RESUME_DOWNLOAD = 1;
my $LOG_FILE;
my $COMPRESS_MODE = 'best';  # 'fast', 'best', or number 1-9
my $SHOW_STATUS = 0;
my $CLEANUP_ONLY = 0;

# === State Variables ===
my $LOOP_DEV;
my $PARTITION;
my $EFI_PARTITION;
my $RESOLV_CONF_SYMLINK_TARGET;
my $RESOLV_CONF_ORIGINAL_TYPE;
my $RESOLV_CONF_BACKUP_FILE;
my $LOG_HANDLE;

# === Color Output ===
my $USE_COLOR = (-t STDOUT) && !$ENV{NO_COLOR};
my %COLOR = (
    reset => $USE_COLOR ? "\033[0m" : "",
    green => $USE_COLOR ? "\033[32m" : "",
    yellow => $USE_COLOR ? "\033[33m" : "",
    red => $USE_COLOR ? "\033[31m" : "",
    blue => $USE_COLOR ? "\033[34m" : "",
    cyan => $USE_COLOR ? "\033[36m" : "",
    bold => $USE_COLOR ? "\033[1m" : "",
);

# === Helper Functions ===
sub log_msg {
    my ($msg, $level) = @_;
    $level ||= 'info';
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime());
    my $log_line = "[$timestamp] [$level] $msg\n";
    
    print $log_line unless $DRY_RUN && $level eq 'debug';
    
    if ($LOG_HANDLE) {
        print $LOG_HANDLE $log_line;
        $| = 1;  # Autoflush
    }
}

sub info { log_msg(shift, 'info'); }
sub warn_msg { log_msg(shift, 'warn'); }
sub error { log_msg(shift, 'error'); }
sub success { log_msg(shift, 'success'); }
sub debug { log_msg(shift, 'debug') if $VERBOSE; }

sub colored {
    my ($text, $color) = @_;
    return $COLOR{$color} . $text . $COLOR{reset};
}

sub show_help {
    print <<EOF;
ARM64 SBC Image Manager

Usage: $0 [OPTIONS]

Options:
  --size SIZE_GB        Target image size in GB (default: 5)
  --url URL            Custom image URL
  --mount DIR          Custom mount directory (default: /mnt/libre_image)
  --qemu-bin PATH      Path to qemu-aarch64-static binary (default: /usr/bin/qemu-aarch64-static)
  --image-xz NAME      Custom .xz filename
  --image-img NAME     Custom .img filename
  --verbose            Enable verbose output
  --force              Force re-download of image
  --skip-chroot        Skip entering chroot (setup only)
  --compress           Compress image with XZ compression after cleanup
  --compress-fast      Use fast compression (level 1)
  --compress-level N   Use compression level 1-9 (default: 9 with -e)
  --output NAME        Output filename for compressed image
  --checksum HASH      Verify image SHA256 checksum
  --checksum-file FILE Read checksums from file (format: hash filename)
  --backup             Create backup of image before modification
  --no-resume          Disable resume of interrupted downloads
  --dry-run            Show what would be done without executing
  --log FILE           Log all operations to file
  --status             Show current status (mounts, loop devices, image info)
  --cleanup-only       Clean up existing mounts and loop devices, then exit
  --help               Show this help message

Exit Codes:
  0  Success
  1  General error
  2  Missing dependencies
  3  Invalid arguments
  4  Not running as root

Examples:
  $0                                    # Use defaults
  $0 --size 10                         # Create 10GB image
  $0 --url https://...                 # Use custom image URL
  $0 --mount /tmp/mount                # Use custom mount directory
  $0 --compress --compress-fast        # Fast compression
  $0 --checksum abc123...              # Verify checksum
  $0 --backup                          # Backup before modification
  $0 --dry-run                         # Show what would be done
  $0 --status                          # Show current status
  $0 --cleanup-only                    # Clean up stuck resources

EOF
    exit EXIT_SUCCESS;
}

sub shell_quote {
    my ($arg) = @_;
    $arg =~ s/'/'\\''/g;
    return "'$arg'";
}

sub validate_path {
    my ($path, $name) = @_;
    if ($path =~ /[;&|`\$\(\)<>]/) {
        die colored("[!] Invalid characters in $name: $path\n", 'red');
    }
    return 1;
}

sub run_safe {
    my ($cmd_ref, $check_exit) = @_;
    $check_exit = 1 unless defined $check_exit;
    
    my @cmd = ref($cmd_ref) eq 'ARRAY' ? @$cmd_ref : ($cmd_ref);
    my $cmd_str = ref($cmd_ref) eq 'ARRAY' ? join(' ', map { shell_quote($_) } @cmd) : $cmd_ref;
    
    if ($DRY_RUN) {
        info(colored("[DRY-RUN] Would run: ", 'cyan') . $cmd_str);
        return { success => 1, output => '', exit_code => 0 };
    }
    
    debug("Running: " . $cmd_str);
    
    my $output = '';
    my $error = '';
    my $exit_code;
    
    if (ref($cmd_ref) eq 'ARRAY' && $HAS_IPC_RUN3) {
        eval {
            IPC::Run3::run3(\@cmd, \undef, \$output, \$error);
            $exit_code = $? >> 8;
        };
        if ($@) {
            # Fallback to shell execution
            $output = `$cmd_str 2>&1`;
            $exit_code = $? >> 8;
        }
    } else {
        # Use shell execution with proper escaping
        $output = `$cmd_str 2>&1`;
        $exit_code = $? >> 8;
    }
    
    if ($check_exit && $exit_code != 0) {
        error(colored("Command failed (exit $exit_code): ", 'red') . $cmd_str);
        if ($error) {
            error("Error output: $error");
        }
        if ($output) {
            error("Output: $output");
        }
        die "Aborting due to command failure\n";
    }
    
    return { success => ($exit_code == 0), output => $output, exit_code => $exit_code };
}

sub run_or_die {
    my ($cmd_ref) = @_;
    my $result = run_safe($cmd_ref, 1);
    return $result->{output};
}

sub run_capture {
    my ($cmd_ref) = @_;
    my $result = run_safe($cmd_ref, 1);
    chomp($result->{output});
    return $result->{output};
}

sub command_exists {
    my ($cmd) = @_;
    my $result = run_safe(['command', '-v', $cmd], 0);
    return $result->{success};
}

sub is_mountpoint {
    my ($path) = @_;
    return 0 unless -e $path;
    my $result = run_safe(['mountpoint', '-q', $path], 0);
    return $result->{success};
}

sub safe_cleanup {
    eval { cleanup(); };
    if ($@) {
        error("Error during cleanup: $@");
        # Force cleanup of critical resources
        system("umount -lf $MOUNT_DIR 2>/dev/null") if $MOUNT_DIR;
        system("losetup -d $LOOP_DEV 2>/dev/null") if $LOOP_DEV;
    }
}

sub cleanup {
    info("Starting cleanup...");

    # Unmount EFI first
    if ($MOUNT_DIR && -d "$MOUNT_DIR/boot/efi" && is_mountpoint("$MOUNT_DIR/boot/efi")) {
        run_or_die(['umount', '-lf', "$MOUNT_DIR/boot/efi"]);
    }

    # Unmount all the bind mounts
    my @bind_dirs = ("/etc/resolv.conf", "/run", "/sys", "/proc", "/dev/pts", "/dev");
    foreach my $dir (@bind_dirs) {
        my $target = "$MOUNT_DIR$dir";
        run_or_die(['umount', '-lf', $target]) if is_mountpoint($target);
    }

    # Restore resolv.conf state BEFORE unmounting the root filesystem
    if ($MOUNT_DIR && is_mountpoint($MOUNT_DIR)) {
        my $chroot_resolv_path = "$MOUNT_DIR/etc/resolv.conf";
        
        # Remove the bind mount point (file) that was created
        unlink($chroot_resolv_path);
        
        if (defined $RESOLV_CONF_ORIGINAL_TYPE) {
            if ($RESOLV_CONF_ORIGINAL_TYPE eq 'symlink' && defined $RESOLV_CONF_SYMLINK_TARGET) {
                info("Restoring resolv.conf symlink...");
                if (symlink($RESOLV_CONF_SYMLINK_TARGET, $chroot_resolv_path)) {
                    success("Successfully restored resolv.conf symlink to '$RESOLV_CONF_SYMLINK_TARGET'.");
                } else {
                    warn_msg("WARNING: Failed to restore resolv.conf symlink: $!");
                }
            } elsif ($RESOLV_CONF_ORIGINAL_TYPE eq 'file' && -f $RESOLV_CONF_BACKUP_FILE) {
                info("Restoring resolv.conf file...");
                if (copy($RESOLV_CONF_BACKUP_FILE, $chroot_resolv_path)) {
                    success("Successfully restored resolv.conf file.");
                    unlink($RESOLV_CONF_BACKUP_FILE);
                } else {
                    warn_msg("WARNING: Failed to restore resolv.conf file: $!");
                }
            } elsif ($RESOLV_CONF_ORIGINAL_TYPE eq 'none') {
                info("Creating default resolv.conf symlink...");
                if (symlink("/run/systemd/resolve/stub-resolv.conf", $chroot_resolv_path)) {
                    success("Created default resolv.conf symlink.");
                } else {
                    warn_msg("WARNING: Failed to create default resolv.conf symlink: $!");
                }
            }
        }
    }

    # Now unmount the main mount point
    run_or_die(['umount', '-lf', $MOUNT_DIR]) if is_mountpoint($MOUNT_DIR);

    # Finally, detach the loop device
    if ($LOOP_DEV) {
        my $result = run_safe(['losetup', $LOOP_DEV], 0);
        if ($result->{success}) {
            run_or_die(['losetup', '-d', $LOOP_DEV]);
        }
    }

    success("Cleanup complete.");
}

sub validate_image {
    my ($image_path) = @_;
    
    info("Validating image integrity...");
    
    unless (-f $image_path) {
        die colored("[!] Image file not found: $image_path\n", 'red');
    }
    
    my $file_type = run_capture(['file', $image_path]);
    unless ($file_type =~ /DOS\/MBR boot sector|Linux.*filesystem|data/) {
        warn_msg("Warning: Unexpected file type: $file_type");
        info("Continuing anyway...");
    }
    
    my $size = (stat($image_path))[7];
    if ($size < MIN_IMAGE_SIZE) {
        die colored("[!] Image file too small (" . format_size($size) . ")\n", 'red');
    }
    
    success("Image validation passed");
}

sub verify_checksum {
    my ($file, $expected_hash) = @_;
    
    unless ($expected_hash) {
        return 1;  # No checksum to verify
    }
    
    info("Verifying SHA256 checksum...");
    
    open(my $fh, '<', $file) or die colored("[!] Cannot open file for checksum: $file\n", 'red');
    binmode($fh);
    my $sha256 = Digest::SHA->new(256);
    $sha256->addfile($fh);
    my $calculated = $sha256->hexdigest;
    close($fh);
    
    if (lc($calculated) eq lc($expected_hash)) {
        success("Checksum verification passed");
        return 1;
    } else {
        error("Checksum mismatch!");
        error("Expected: $expected_hash");
        error("Got:      $calculated");
        return 0;
    }
}

sub check_existing_work {
    if (-f $IMAGE_IMG) {
        info("Found existing image: $IMAGE_IMG");
        unless ($FORCE_DOWNLOAD) {
            info("Use --force to re-download");
            return 1;
        }
    }
    return 0;
}

sub download_image {
    my ($url, $output_file) = @_;
    
    info("Downloading image from: $url");
    
    my @wget_cmd = ('wget', '-O', $output_file);
    push @wget_cmd, '--continue' if $RESUME_DOWNLOAD && -f $output_file;
    push @wget_cmd, '--progress=bar:force:noscroll' if -t STDOUT;
    push @wget_cmd, $url;
    
    run_or_die(\@wget_cmd);
    success("Download complete");
}

sub extract_image {
    my ($xz_file, $img_file) = @_;
    
    info("Extracting image...");
    
    if (-t STDOUT) {
        # Show progress with verbose xz
        run_or_die(['xz', '-dkv', $xz_file]);
    } else {
        run_or_die(['xz', '-dk', $xz_file]);
    }
    
    success("Extraction complete");
}

sub grow_image {
    info("Checking image size...");
    my $size = (stat($IMAGE_IMG))[7];
    my $target = $IMAGE_SIZE_GB * 1024 * 1024 * 1024;

    if ($size >= $target) {
        info("Image is already >= ${IMAGE_SIZE_GB}GB, skipping resize.");
        return;
    }

    info("Growing image file to ${IMAGE_SIZE_GB}GB...");
    run_or_die(['truncate', '-s', "${IMAGE_SIZE_GB}G", $IMAGE_IMG]);

    my $loopdev = run_capture(['losetup', '--show', '-Pf', $IMAGE_IMG]);
    die colored("[!] Failed to setup loop device.\n", 'red') unless $loopdev;

    my $sector_size = run_capture(['blockdev', '--getss', $loopdev]);
    my $disk_sectors = run_capture(['blockdev', '--getsz', $loopdev]);

    info("Disk size: " . int($disk_sectors * $sector_size / 1024 / 1024) . "MB");

    my $parted_output = run_capture(['parted', '-ms', $loopdev, 'unit', 's', 'print']);
    my @part_lines = grep { !/^BYT/ && !/^\/dev/ } split(/\n/, $parted_output);
    die colored("[!] No partitions found.\n", 'red') unless @part_lines;

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

    die colored("[!] Failed to determine root partition.\n", 'red') unless $root_num;

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
    die colored("[!] No space to expand root partition.\n", 'red') if $new_end_sector <= $root_start;

    my $new_end_mb = int($new_end_sector * $sector_size / 1024 / 1024);
    info("Resizing partition $root_num to ~${new_end_mb}MB...");
    run_or_die(['parted', '-s', $loopdev, 'resizepart', $root_num, "${new_end_mb}MB"]);

    run_or_die(['partprobe', $loopdev]);
    sleep(1);
    run_or_die(['losetup', '-d', $loopdev]);
}

sub format_size {
    my ($bytes) = @_;
    my @units = qw(B KB MB GB TB);
    my $unit = 0;
    my $size = $bytes;
    
    while ($size >= 1024 && $unit < $#units) {
        $size /= 1024;
        $unit++;
    }
    
    return sprintf("%.1f %s", $size, $units[$unit]);
}

sub detect_and_resize_fs {
    my ($partition) = @_;
    
    my $fs_type = run_capture(['blkid', '-o', 'value', '-s', 'TYPE', $partition]);
    info("Detected filesystem: $fs_type");
    
    if ($fs_type eq "ext4") {
        info("Resizing ext4 filesystem...");
        run_or_die(['e2fsck', '-f', '-y', $partition]);
        run_or_die(['resize2fs', $partition]);
    } elsif ($fs_type eq "btrfs") {
        info("Resizing Btrfs filesystem...");
        run_or_die(['btrfs', 'filesystem', 'resize', 'max', $MOUNT_DIR]);
    } elsif ($fs_type eq "xfs") {
        warn_msg("XFS detected - manual resize may be needed");
        warn_msg("XFS requires offline resize. Consider using a larger image.");
    } elsif ($fs_type eq "vfat" || $fs_type eq "fat32") {
        info("FAT filesystem detected - skipping resize");
    } else {
        warn_msg("Unknown filesystem type: $fs_type");
        info("Skipping filesystem resize");
    }
}

sub compress_image {
    my ($input_image, $output_name) = @_;
    
    unless (-f $input_image) {
        die colored("[!] Input image not found: $input_image\n", 'red');
    }
    
    if (!$output_name) {
        my ($name, $ext) = $input_image =~ /(.+)\.(.+)$/;
        $output_name = "${name}_compressed.xz";
    }
    
    $output_name .= ".xz" unless $output_name =~ /\.xz$/;
    
    if (-f $output_name) {
        warn_msg("Output file already exists: $output_name");
        info("Overwriting existing file...");
    }
    
    my $comp_level = 9;
    my $extreme = 1;
    
    if ($COMPRESS_MODE eq 'fast') {
        $comp_level = 1;
        $extreme = 0;
    } elsif ($COMPRESS_MODE =~ /^\d+$/) {
        $comp_level = int($COMPRESS_MODE);
        $comp_level = 9 if $comp_level > 9;
        $comp_level = 1 if $comp_level < 1;
        $extreme = 0 if $comp_level < 9;
    }
    
    my $comp_desc = $extreme ? "best XZ compression (level $comp_level -e)" : "XZ compression (level $comp_level)";
    info("Compressing image with $comp_desc...");
    info("This may take a while depending on image size...");
    
    my $original_size = (stat($input_image))[7];
    info("Original image size: " . format_size($original_size));
    
    my @xz_cmd = ('xz', "-$comp_level");
    push @xz_cmd, '-e' if $extreme;
    push @xz_cmd, '-v' if -t STDOUT && $VERBOSE;  # Verbose progress to stderr when in terminal
    push @xz_cmd, '-c', $input_image;
    
    # Use shell redirection for xz output
    my $xz_cmd_str = join(' ', map { shell_quote($_) } @xz_cmd) . " > " . shell_quote($output_name);
    my $result = run_safe($xz_cmd_str);
    
    unless ($result->{success} && -f $output_name) {
        unlink($output_name) if -f $output_name;
        die colored("[!] Compression failed\n", 'red');
    }
    
    my $compressed_size = (stat($output_name))[7];
    my $compression_ratio = sprintf("%.1f", (1 - $compressed_size / $original_size) * 100);
    
    success("Compression complete!");
    info("Original size: " . format_size($original_size));
    info("Compressed size: " . format_size($compressed_size));
    info("Compression ratio: ${compression_ratio}%");
    info("Output file: $output_name");
    
    info("Verifying compressed image integrity...");
    run_or_die(['xz', '-t', $output_name]);
    success("Compressed image verification passed");
}

sub show_status {
    print colored("\n=== SBC Image Manager Status ===\n\n", 'bold');
    
    # Check mounts
    print colored("Mount Points:\n", 'cyan');
    if (is_mountpoint($MOUNT_DIR)) {
        print colored("  [MOUNTED] ", 'green') . "$MOUNT_DIR\n";
        
        # Check bind mounts
        my @bind_dirs = ("/dev", "/dev/pts", "/proc", "/sys", "/run", "/etc/resolv.conf");
        foreach my $dir (@bind_dirs) {
            my $target = "$MOUNT_DIR$dir";
            if (is_mountpoint($target)) {
                print colored("  [MOUNTED] ", 'green') . "$target\n";
            }
        }
        
        if (-d "$MOUNT_DIR/boot/efi" && is_mountpoint("$MOUNT_DIR/boot/efi")) {
            print colored("  [MOUNTED] ", 'green') . "$MOUNT_DIR/boot/efi\n";
        }
    } else {
        print colored("  [NOT MOUNTED] ", 'yellow') . "$MOUNT_DIR\n";
    }
    
    # Check loop devices
    print colored("\nLoop Devices:\n", 'cyan');
    my $loop_output = `losetup -a 2>/dev/null | grep -E "$IMAGE_IMG|$IMAGE_XZ" || true`;
    if ($loop_output) {
        chomp($loop_output);
        my @loops = split(/\n/, $loop_output);
        foreach my $loop (@loops) {
            print colored("  [ACTIVE] ", 'green') . "$loop\n";
        }
    } else {
        print colored("  [NONE] ", 'yellow') . "No active loop devices for this image\n";
    }
    
    # Image info
    print colored("\nImage Files:\n", 'cyan');
    if (-f $IMAGE_XZ) {
        my $size = format_size((stat($IMAGE_XZ))[7]);
        print colored("  [EXISTS] ", 'green') . "$IMAGE_XZ ($size)\n";
    } else {
        print colored("  [MISSING] ", 'yellow') . "$IMAGE_XZ\n";
    }
    
    if (-f $IMAGE_IMG) {
        my $size = format_size((stat($IMAGE_IMG))[7]);
        print colored("  [EXISTS] ", 'green') . "$IMAGE_IMG ($size)\n";
    } else {
        print colored("  [MISSING] ", 'yellow') . "$IMAGE_IMG\n";
    }
    
    print "\n";
    exit EXIT_SUCCESS;
}

sub cleanup_only {
    info("Cleanup-only mode: cleaning up existing resources...");
    
    # Clean up loop devices
    my $loop_output = `losetup -a 2>/dev/null | grep -E "$IMAGE_IMG|$IMAGE_XZ" || true`;
    if ($loop_output) {
        chomp($loop_output);
        my @loops = split(/\n/, $loop_output);
        foreach my $loop_line (@loops) {
            if ($loop_line =~ /^(\/dev\/loop\d+):/) {
                my $loop_dev = $1;
                info("Detaching loop device: $loop_dev");
                system("losetup -d $loop_dev 2>/dev/null");
            }
        }
    }
    
    # Clean up mounts
    if (is_mountpoint($MOUNT_DIR)) {
        info("Unmounting: $MOUNT_DIR");
        system("umount -lf $MOUNT_DIR 2>/dev/null");
    }
    
    success("Cleanup complete");
    exit EXIT_SUCCESS;
}

# === Main Logic ===
$SIG{INT} = $SIG{TERM} = sub { safe_cleanup(); exit EXIT_GENERAL_ERROR };

# Parse command line arguments
GetOptions(
    "size=i" => \$IMAGE_SIZE_GB,
    "url=s" => \$CUSTOM_IMAGE_URL,
    "mount=s" => \$CUSTOM_MOUNT_DIR,
    "qemu-bin=s" => \$CUSTOM_QEMU_BIN,
    "image-xz=s" => \$CUSTOM_IMAGE_XZ,
    "image-img=s" => \$CUSTOM_IMAGE_IMG,
    "verbose" => \$VERBOSE,
    "force" => \$FORCE_DOWNLOAD,
    "skip-chroot" => \$SKIP_CHROOT,
    "compress" => \$COMPRESS_IMAGE,
    "compress-fast" => sub { $COMPRESS_IMAGE = 1; $COMPRESS_MODE = 'fast'; },
    "compress-level=i" => sub { $COMPRESS_IMAGE = 1; $COMPRESS_MODE = $_[1]; },
    "output=s" => \$OUTPUT_NAME,
    "checksum=s" => \$CHECKSUM,
    "checksum-file=s" => \$CHECKSUM_FILE,
    "backup" => \$BACKUP_IMAGE,
    "no-resume" => sub { $RESUME_DOWNLOAD = 0; },
    "dry-run" => \$DRY_RUN,
    "log=s" => \$LOG_FILE,
    "status" => \$SHOW_STATUS,
    "cleanup-only" => \$CLEANUP_ONLY,
    "help" => \&show_help,
) or exit EXIT_INVALID_ARGS;

# Check for root
unless ($DRY_RUN || $SHOW_STATUS || $CLEANUP_ONLY) {
    if ($< != 0) {
        die colored("[!] This script must be run as root\n", 'red');
        exit EXIT_NOT_ROOT;
    }
}

# Open log file if specified
if ($LOG_FILE) {
    open($LOG_HANDLE, '>>', $LOG_FILE) or die colored("[!] Cannot open log file: $LOG_FILE\n", 'red');
    info("Logging to: $LOG_FILE");
}

# Use custom values if provided
$IMAGE_URL = $CUSTOM_IMAGE_URL if $CUSTOM_IMAGE_URL;
$MOUNT_DIR = $CUSTOM_MOUNT_DIR if $CUSTOM_MOUNT_DIR;
$QEMU_BIN = $CUSTOM_QEMU_BIN if $CUSTOM_QEMU_BIN;
$IMAGE_XZ = $CUSTOM_IMAGE_XZ if $CUSTOM_IMAGE_XZ;
$IMAGE_IMG = $CUSTOM_IMAGE_IMG if $CUSTOM_IMAGE_IMG;

# Validate paths
validate_path($MOUNT_DIR, 'mount directory');
validate_path($IMAGE_XZ, 'image xz filename');
validate_path($IMAGE_IMG, 'image img filename');
validate_path($QEMU_BIN, 'qemu binary path') if $QEMU_BIN;

# Handle status and cleanup-only modes
if ($SHOW_STATUS) {
    show_status();
}

if ($CLEANUP_ONLY) {
    cleanup_only();
}

# Handle checksum file
if ($CHECKSUM_FILE && -f $CHECKSUM_FILE) {
    open(my $fh, '<', $CHECKSUM_FILE) or die colored("[!] Cannot read checksum file: $CHECKSUM_FILE\n", 'red');
    while (my $line = <$fh>) {
        chomp($line);
        next if $line =~ /^\s*#/ || $line =~ /^\s*$/;
        if ($line =~ /^(\w+)\s+(.+)$/) {
            my ($hash, $file) = ($1, $2);
            if ($file eq $IMAGE_XZ || $file eq $IMAGE_IMG) {
                $CHECKSUM = $hash;
                last;
            }
        }
    }
    close($fh);
}

print colored("\n=== ARM64 SBC Image Manager ===\n\n", 'bold');
info("Target size: ${IMAGE_SIZE_GB}GB");
info("Mount directory: $MOUNT_DIR");
info("Image URL: $IMAGE_URL");
info("QEMU binary: $QEMU_BIN");
info("Image files: $IMAGE_XZ -> $IMAGE_IMG");
info("Verbose mode: " . ($VERBOSE ? "enabled" : "disabled"));
info("Compression mode: " . ($COMPRESS_IMAGE ? "enabled ($COMPRESS_MODE)" : "disabled"));
info("Dry-run mode: " . ($DRY_RUN ? "enabled" : "disabled"));
if ($COMPRESS_IMAGE && $OUTPUT_NAME) {
    info("Output file: $OUTPUT_NAME");
}
if ($CHECKSUM) {
    info("Checksum verification: enabled");
}
if ($BACKUP_IMAGE) {
    info("Backup mode: enabled");
}
print "\n";

# Check dependencies
foreach my $cmd (qw/wget xz losetup mount chroot qemu-aarch64-static parted e2fsck resize2fs partprobe btrfs blkid lsblk/) {
    unless (command_exists($cmd)) {
        die colored("[!] Missing required command: $cmd\n", 'red');
        exit EXIT_MISSING_DEPS;
    }
}

unless (-x $QEMU_BIN) {
    die colored("[!] $QEMU_BIN not found or not executable\n", 'red');
    exit EXIT_MISSING_DEPS;
}

make_path($MOUNT_DIR) unless $DRY_RUN;

# Cleanup previous state
info("Cleaning up previous state...");
my $loop_output = `losetup -a 2>/dev/null | grep "$IMAGE_IMG" || true`;
if ($loop_output) {
    chomp($loop_output);
    my @old_loops = map { /^(\/dev\/loop\d+):/ ? $1 : () } split(/\n/, $loop_output);
    foreach my $dev (@old_loops) {
        run_or_die(['losetup', '-d', $dev]);
    }
}

# Check for existing work
unless (check_existing_work()) {
    download_image($IMAGE_URL, $IMAGE_XZ);
    
    # Verify checksum if provided
    if ($CHECKSUM) {
        unless (verify_checksum($IMAGE_XZ, $CHECKSUM)) {
            unlink($IMAGE_XZ);
            die colored("[!] Checksum verification failed. Download may be corrupted.\n", 'red');
            exit EXIT_GENERAL_ERROR;
        }
    }
    
    extract_image($IMAGE_XZ, $IMAGE_IMG);
}

# Validate the image
validate_image($IMAGE_IMG);

# Create backup if requested
if ($BACKUP_IMAGE && -f $IMAGE_IMG) {
    my $backup_name = "${IMAGE_IMG}.backup";
    info("Creating backup: $backup_name");
    copy($IMAGE_IMG, $backup_name) or die colored("[!] Failed to create backup\n", 'red');
    success("Backup created: $backup_name");
}

grow_image();

info("Attaching image to loop device...");
$LOOP_DEV = run_capture(['losetup', '--show', '-Pf', $IMAGE_IMG]);
die colored("[!] Failed to setup loop device.\n", 'red') unless $LOOP_DEV;

my $lsblk_output = run_capture(['lsblk', '-lnp', '-o', 'NAME,TYPE', $LOOP_DEV]);
my @partitions = grep { /part/ } split(/\n/, $lsblk_output);
if (@partitions) {
    info("Partitioned image detected.");
    my $sizes_output = run_capture(['lsblk', '-lnp', '-o', 'NAME,SIZE,TYPE', $LOOP_DEV]);
    my @sizes = grep { /part/ } split(/\n/, $sizes_output);
    @sizes = sort { 
        my ($a_size) = $a =~ /(\d+[KMGT]?)/;
        my ($b_size) = $b =~ /(\d+[KMGT]?)/;
        $a_size cmp $b_size;
    } @sizes;
    ($PARTITION) = split(' ', $sizes[-1]);
} else {
    info("Unpartitioned image detected.");
    $PARTITION = $LOOP_DEV;
}

die colored("[!] Failed to detect root partition.\n", 'red') unless $PARTITION;

info("Using root partition: $PARTITION");
run_or_die(['mount', $PARTITION, $MOUNT_DIR]);

detect_and_resize_fs($PARTITION);

# Sanity Check
unless (-d "$MOUNT_DIR/etc") {
    error("/etc directory not found after mounting root filesystem.");
    error("Likely indicates an empty or improperly configured image.");
    cleanup();
    exit EXIT_GENERAL_ERROR;
}

# Handle resolv.conf state preservation
my $chroot_resolv_path = "$MOUNT_DIR/etc/resolv.conf";
$RESOLV_CONF_BACKUP_FILE = "/tmp/resolv_conf_backup_$$";

# Determine the original state and preserve it
if (-l $chroot_resolv_path) {
    $RESOLV_CONF_ORIGINAL_TYPE = 'symlink';
    $RESOLV_CONF_SYMLINK_TARGET = readlink($chroot_resolv_path);
    die colored("[!] Failed to read resolv.conf symlink\n", 'red') unless defined $RESOLV_CONF_SYMLINK_TARGET;
    info("Found resolv.conf symlink to '$RESOLV_CONF_SYMLINK_TARGET'. Storing for restoration.");
} elsif (-f $chroot_resolv_path) {
    $RESOLV_CONF_ORIGINAL_TYPE = 'file';
    copy($chroot_resolv_path, $RESOLV_CONF_BACKUP_FILE) or die colored("[!] Failed to backup resolv.conf\n", 'red');
    info("Found resolv.conf file. Backed up content for restoration.");
} else {
    $RESOLV_CONF_ORIGINAL_TYPE = 'none';
    info("No resolv.conf found in image. Will create symlink on cleanup.");
}

# Remove the original to prepare for bind mount
if (-e $chroot_resolv_path || -l $chroot_resolv_path) {
    info("Temporarily removing existing $chroot_resolv_path for chroot networking.");
    unlink($chroot_resolv_path) or die colored("[!] Failed to remove existing resolv.conf: $!\n", 'red');
}

# Create an empty file to act as the mount point
info("Creating temporary mount point for /etc/resolv.conf.");
run_or_die(['touch', $chroot_resolv_path]);

# EFI Mount if present
if (@partitions) {
    my $efi_output = run_capture(['lsblk', '-lnp', $LOOP_DEV, '-o', 'NAME,FSTYPE']);
    my @efi_lines = grep { /vfat/i } split(/\n/, $efi_output);
    if (@efi_lines) {
        ($EFI_PARTITION) = split(' ', $efi_lines[0]);
        run_or_die(['mkdir', '-p', "$MOUNT_DIR/boot/efi"]);
        run_or_die(['mount', $EFI_PARTITION, "$MOUNT_DIR/boot/efi"]);
    }
}

# Bind Mounts
my @binds = ("/dev", "/dev/pts", "/proc", "/sys", "/run");
foreach my $dir (@binds) {
    run_or_die(['mount', '--bind', $dir, "$MOUNT_DIR$dir"]);
}
run_or_die(['mount', '--bind', '/etc/resolv.conf', "$MOUNT_DIR/etc/resolv.conf"]);
run_or_die(['cp', $QEMU_BIN, "$MOUNT_DIR/usr/bin/"]);

if ($SKIP_CHROOT) {
    info("Skipping chroot (setup only mode)");
    info("Image is mounted at: $MOUNT_DIR");
    info("Run cleanup manually when done");
} else {
    print "\n";
    info(colored("Entering ARM64 chroot...", 'green'));
    system('chroot', $MOUNT_DIR, '/usr/bin/qemu-aarch64-static', '/bin/bash');
}

cleanup();

# Compress image if requested
if ($COMPRESS_IMAGE) {
    print "\n";
    info("Starting image compression...");
    compress_image($IMAGE_IMG, $OUTPUT_NAME);
}

success(colored("Done. Image is unmounted and clean.", 'green'));

close($LOG_HANDLE) if $LOG_HANDLE;
exit EXIT_SUCCESS;
