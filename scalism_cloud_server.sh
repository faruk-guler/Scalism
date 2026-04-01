#!/bin/bash
set -euo pipefail

# ============================================================
# Scalism 1.0 — Hybrid Live ISO Builder
# Based on Debian 13 (Trixie) — minimal server distribution
# BIOS + UEFI | Bare metal + VMware + Hyper-V + VirtualBox + QEMU
# Login: root / root
# ============================================================

DISTRO="bookworm"
ARCH="amd64"
MIRROR="https://deb.debian.org/debian"
ISO_NAME="scalism-1.0-cloud-amd64.iso"
WORK_DIR="$(mktemp -d -p ./ isobuild.XXXXXX)"
ROOTFS="$WORK_DIR/rootfs"
ISO_DIR="$WORK_DIR/isodir"

# Root Check (Since sudo might not be installed)
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

echo "==> Working directory: $WORK_DIR"

# --- Packages ---
PACKAGES=(
  # Core system
  linux-image-cloud-amd64
  systemd systemd-sysv dbus
  bash coreutils util-linux

  # Required for live boot
  live-boot live-boot-initramfs-tools live-config
  initramfs-tools

  # Network
  iproute2 ifupdown
  openssh-server ca-certificates
  systemd-resolved

  # VM integration (all platforms)
  hyperv-daemons          # Hyper-V Gen1 + Gen2
  open-vm-tools           # VMware
  virtualbox-guest-utils  # VirtualBox
  # QEMU/KVM: no guest agent needed for basic boot

  # Package management
  busybox

  # Installer dependencies
  parted dosfstools rsync efibootmgr e2fsprogs grub-pc-bin grub-efi-amd64-bin grub2-common
)

# ============================================================
echo "[0/7] Installing host dependencies..."
# ============================================================
apt update && apt install -y \
  mmdebstrap \
  squashfs-tools \
  xorriso \
  grub-pc-bin \
  grub-efi-amd64-bin \
  dosfstools \
  mtools \
  ovmf

# ============================================================
echo "[1/7] Building rootfs (mmdebstrap)..."
# ============================================================
mkdir -p "$ROOTFS"

DEBIAN_FRONTEND=noninteractive mmdebstrap \
  --variant=apt \
  --arch="$ARCH" \
  --include="apt,$(IFS=,; echo "${PACKAGES[*]}")" \
  --setup-hook='mkdir -p "$1/proc"; mount -t proc proc "$1/proc"' \
  --setup-hook='mkdir -p "$1/sys"; mount -t sysfs sysfs "$1/sys"' \
  --setup-hook='mkdir -p "$1/dev"; mount --bind /dev "$1/dev"' \
  --customize-hook='
    # Hostname
    echo "scalism" > "$1/etc/hostname"
    echo "127.0.1.1 scalism" >> "$1/etc/hosts"

    # Root password
    echo "root:root" | chroot "$1" chpasswd

    # SSH: enable root login
    sed -i "s/#PermitRootLogin.*/PermitRootLogin yes/" \
      "$1/etc/ssh/sshd_config"

    # Network: DHCP
    cat > "$1/etc/network/interfaces" <<NET
auto lo
iface lo inet loopback
NET

    # Live-boot config
    mkdir -p "$1/etc/live"
    cat > "$1/etc/live/config.conf" <<LIVE
LIVE_HOSTNAME="scalism"
LIVE_USERNAME="root"
LIVE

    # OS branding
    cat > "$1/etc/os-release" <<OSREL
PRETTY_NAME="Scalism 1.0 Cloud"
NAME="Scalism"
VERSION_ID="1.0"
VERSION="1.0"
ID=scalism
ID_LIKE=debian
HOME_URL="https://scalism.io"
SUPPORT_URL="https://scalism.io"
BUG_REPORT_URL="https://scalism.io"
OSREL

    # Timezone: Default to UTC
    ln -sf /usr/share/zoneinfo/UTC "$1/etc/localtime"
    echo "UTC" > "$1/etc/timezone"

    # Installer Script
    cat > "$1/usr/local/bin/scalism-install" <<EOF
#!/bin/bash
set -eo pipefail

if [ "\$EUID" -ne 0 ]; then
  echo "Error: Please run as root."
  exit 1
fi

echo "============================================================"
echo "    SCALISM INSTALLER"
echo "============================================================"

# List available disks
echo "Detecting available disks..."
lsblk -do NAME,SIZE,MODEL | grep -v "NAME" || true
echo "------------------------------------------------------------"

TARGET=\${1:-""}

if [ -z "\$TARGET" ]; then
    read -p "Enter target disk (e.g., /dev/sda or /dev/nvme0n1): " TARGET
fi

if [ ! -b "\$TARGET" ]; then
    echo "Error: Device \$TARGET does not exist or is not a block device."
    exit 1
fi

echo "WARNING: This will erase ALL DATA on \$TARGET!"
read -p "Are you absolutely sure? (y/N): " CONFIRM
if [[ ! "\$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborting."
    exit 1
fi

echo "[1/5] Partitioning \$TARGET (GPT)..."
# Clean potential RAID/LVM metadata
wipefs -af "\$TARGET"
# GPT Table
parted -s "\$TARGET" mklabel gpt
# BIOS Boot (for Legacy BIOS support on GPT)
parted -s "\$TARGET" mkpart bios_grub 1MiB 2MiB
parted -s "\$TARGET" set 1 bios_grub on
# EFI Partition
parted -s "\$TARGET" mkpart efi fat32 2MiB 514MiB
parted -s "\$TARGET" set 2 esp on
# Root Partition
parted -s "\$TARGET" mkpart root ext4 514MiB 100%

sleep 2

# Detect partition suffix (p for nvme/mmc)
if [[ "\$TARGET" == *"nvme"* ]] || [[ "\$TARGET" == *"mmc"* ]]; then
  P="p"
else
  P=""
fi

echo "[2/5] Formatting partitions..."
mkfs.vfat -F32 "\${TARGET}\${P}2"
mkfs.ext4 -F "\${TARGET}\${P}3"

echo "[3/5] Cloning OS to disk..."
mkdir -p /mnt/scalism
mount "\${TARGET}\${P}3" /mnt/scalism
mkdir -p /mnt/scalism/boot/efi
mount "\${TARGET}\${P}2" /mnt/scalism/boot/efi

# Copy files while preserving permissions and excluding virtual filesystems
rsync -aAXv --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/cdrom/*"} / /mnt/scalism/

echo "[4/5] Configuring fstab..."
ROOT_UUID=\$(blkid -s UUID -o value "\${TARGET}\${P}3")
EFI_UUID=\$(blkid -s UUID -o value "\${TARGET}\${P}2")

cat > /mnt/scalism/etc/fstab <<FSTAB
UUID=\$ROOT_UUID / ext4 defaults,errors=remount-ro 0 1
UUID=\$EFI_UUID /boot/efi vfat umask=0077 0 1
FSTAB

# Remove live-boot specific configs from installed system
rm -f /mnt/scalism/etc/live/config.conf || true

echo "[5/5] Installing GRUB Bootloader..."
# Mount virtual filesystems for chroot
for i in /dev /dev/pts /proc /sys /run; do mount -B \$i /mnt/scalism\$i; done

# Install for both BIOS and UEFI
echo "Installing BIOS GRUB..."
chroot /mnt/scalism grub-install --target=i386-pc "\$TARGET"
echo "Installing UEFI GRUB..."
chroot /mnt/scalism grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=SCALISM --recheck
chroot /mnt/scalism update-grub

# Unmount
for i in /run /sys /proc /dev/pts /dev; do umount /mnt/scalism\$i; done
umount /mnt/scalism/boot/efi
umount /mnt/scalism

sync
echo "============================================================"
echo " ✅ INSTALLATION COMPLETE!"
echo " You can now remove the installation media and reboot."
echo "============================================================"
EOF
    chmod +x "$1/usr/local/bin/scalism-install"

    # Strip locale data (saves ~20MB)
    find "$1/usr/share/locale" -mindepth 1 -maxdepth 1 \
      ! -name "en" ! -name "en_US" -exec rm -rf {} +

    # Strip unused locale from lib
    find "$1/usr/lib/locale" -mindepth 1 -maxdepth 1 \
      ! -name "C.UTF-8" -exec rm -rf {} + 2>/dev/null || true

    # Advanced Initramfs Compression (XZ)
    sed -i "s/^COMPRESS=.*/COMPRESS=xz/" "$1/etc/initramfs-tools/initramfs.conf"

    # BusyBox Integration: Keep it available but don't symlink to /bin to avoid conflicts
    # chroot "$1" busybox --install -s /bin
    mkdir -p "$1/usr/local/bin"
    chroot "$1" ln -sf /bin/busybox /usr/local/bin/busybox

    # Cleanup Firmware: Be more conservative during stabilization
    # find "$1/lib/firmware" ... (temporarily disabled)
    
    find "$1/lib/modules" -type d -name "wireless" -exec rm -rf {} +
    find "$1/lib/modules" -type d -name "sound" -exec rm -rf {} +
    find "$1/lib/modules" -type d -name "drivers/gpu" -exec rm -rf {} +
    find "$1/lib/modules" -type d -name "drivers/media" -exec rm -rf {} +
    
    # Networking: systemd-networkd for DHCP on all interfaces
    # We rely on systemd-networkd + resolved
    cat > "$1/etc/systemd/network/20-wired.network" <<NET
[Match]
Name=en* eth*

[Network]
DHCP=yes
NET
    systemctl --root="$1" enable systemd-networkd systemd-resolved

    # Update initramfs inside chroot (temporarily disabled for stability)
    # chroot "$1" update-initramfs -u

    # Cleanup
    umount "$1/dev" "$1/sys" "$1/proc" || true
  ' \
  "$DISTRO" "$ROOTFS" "$MIRROR"

# ============================================================
echo "[2/7] Copying kernel and initrd..."
# ============================================================
mkdir -p "$ISO_DIR/live" "$ISO_DIR/boot/grub"

VMLINUZ=$(ls "$ROOTFS/boot/vmlinuz-"* | sort -V | tail -1)
INITRD=$(ls  "$ROOTFS/boot/initrd.img-"* | sort -V | tail -1)
cp "$VMLINUZ" "$ISO_DIR/live/vmlinuz"
cp "$INITRD"  "$ISO_DIR/live/initrd.img"
echo "    Kernel: $(basename $VMLINUZ)"

# ============================================================
echo "[3/7] Building SquashFS (xz compression)..."
# ============================================================
mksquashfs "$ROOTFS" "$ISO_DIR/live/filesystem.squashfs" \
  -comp xz -b 1M -Xdict-size 100% -Xbcj x86 -noappend -quiet \
  -e "$ROOTFS/proc" -e "$ROOTFS/sys" -e "$ROOTFS/dev"

echo "    SquashFS size: $(du -sh "$ISO_DIR/live/filesystem.squashfs" | cut -f1)"

# ============================================================
echo "[4/7] Writing GRUB configuration..."
# ============================================================
cat > "$ISO_DIR/boot/grub/grub.cfg" <<'GRUBCFG'
# Search for the ISO root
insmod part_gpt
insmod part_msdos
insmod fat
insmod iso9660
insmod ntfs
insmod ntfscomp
insmod ext2

search --no-floppy --file --set=root /live/vmlinuz

set default=0
set timeout=5

# VGA + serial console
terminal_input  serial console
terminal_output serial console
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1

menuentry "Scalism 1.0 Cloud" {
    linux  /live/vmlinuz boot=live components quiet console=tty0 console=ttyS0,115200n8
    initrd /live/initrd.img
}

menuentry "Scalism 1.0 Cloud (Debug / verbose)" {
    linux  /live/vmlinuz boot=live components console=tty0 console=ttyS0,115200n8
    initrd /live/initrd.img
}
GRUBCFG

# ============================================================
echo "[5/7] Building EFI image (UEFI support)..."
# ============================================================
mkdir -p "$ISO_DIR/EFI/BOOT"

grub-mkstandalone \
  --format=x86_64-efi \
  --output="$ISO_DIR/EFI/BOOT/BOOTX64.EFI" \
  --install-modules="linux normal iso9660 search search_fs_file part_gpt part_msdos fat test" \
  --modules="linux normal iso9660 search search_fs_file part_gpt part_msdos fat" \
  --locales="" --fonts="" \
  "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg"

EFI_IMG="$WORK_DIR/efi.img"
dd if=/dev/zero of="$EFI_IMG" bs=1M count=4 status=none
mkfs.vfat "$EFI_IMG"
mmd   -i "$EFI_IMG" ::/EFI ::/EFI/BOOT
mcopy -i "$EFI_IMG" "$ISO_DIR/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/
cp "$EFI_IMG" "$ISO_DIR/boot/efi.img"

# ============================================================
echo "[6/7] Building BIOS GRUB image..."
# ============================================================
grub-mkstandalone \
  --format=i386-pc \
  --output="$WORK_DIR/core.img" \
  --install-modules="linux normal iso9660 biosdisk memdisk search search_fs_file part_gpt part_msdos tar ls test" \
  --modules="linux normal iso9660 biosdisk search search_fs_file part_gpt part_msdos" \
  --locales="" --fonts="" \
  "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg"

cat /usr/lib/grub/i386-pc/cdboot.img "$WORK_DIR/core.img" \
  > "$ISO_DIR/boot/grub/bios.img"

# ============================================================
echo "[7/7] Creating hybrid ISO (xorriso)..."
# ============================================================
xorriso -as mkisofs \
  -iso-level 3 \
  -volid "SCALISM_1_0" \
  -full-iso9660-filenames \
  \
  -b boot/grub/bios.img \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    --grub2-boot-info \
    --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
  \
  -eltorito-alt-boot \
  -e boot/efi.img \
    -no-emul-boot \
    --efi-boot-part \
    --efi-boot-image \
  \
  -append_partition 2 0xef "$ISO_DIR/boot/efi.img" \
  \
  -output "$ISO_NAME" \
  "$ISO_DIR"

# --- Cleanup ---
rm -rf "$WORK_DIR"

# --- Done ---
ISO_SIZE=$(du -sh "$ISO_NAME" | cut -f1)
echo ""
echo "================================================"
echo " ██████  ██████  █████  ██      ██ ███████ ███    ███"
echo " ██      ██     ██   ██ ██      ██ ██      ████  ████"
echo " ███████ ██     ███████ ██      ██ ███████ ██ ████ ██"
echo "      ██ ██     ██   ██ ██      ██      ██ ██  ██  ██"
echo " ██████  ██████ ██   ██ ███████ ██ ███████ ██      ██"
echo ""
echo " Scalism 1.0 Cloud — VM Optimized"
echo " ISO: $ISO_NAME ($ISO_SIZE)"
echo ""
echo " Test (BIOS):"
echo "   qemu-system-x86_64 -cdrom $ISO_NAME -m 512M -nographic"
echo ""
echo " Test (UEFI):"
echo "   qemu-system-x86_64 -cdrom $ISO_NAME -m 512M \\"
echo "     -bios /usr/share/ovmf/OVMF.fd -nographic"
echo ""
echo " Write to USB (bare metal):"
echo "   sudo dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress && sync"
echo ""
echo " Login: root / root"
echo "================================================"
