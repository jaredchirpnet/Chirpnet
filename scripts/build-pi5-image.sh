#!/usr/bin/env bash
set -euo pipefail

ROOTFS_DIR="${ROOTFS_DIR:-$(pwd)/build/rootfs}"
RELEASE="${DEBIAN_RELEASE:-bookworm}"
IMG_FILE="${IMG_FILE:-$(pwd)/build/debian-pi5-${RELEASE}.img}"
IMAGE_SIZE="${IMAGE_SIZE:-8G}"
BOOT_SIZE="${BOOT_SIZE:-256MiB}"

BOOT_MNT="$(pwd)/mnt/boot"
ROOT_MNT="$(pwd)/mnt/root"
LOOP_DEVICE=""

cleanup() {
  # Unmount the chroot's pseudo-filesystems first; they are nested deepest.
  for d in dev/pts dev proc sys; do
    sudo umount -l "$ROOTFS_DIR/$d" 2>/dev/null || true
  done
  sudo umount -l "$BOOT_MNT" 2>/dev/null || true
  sudo umount -l "$ROOT_MNT" 2>/dev/null || true
  if [ -n "$LOOP_DEVICE" ]; then
    sudo losetup -d "$LOOP_DEVICE" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# rm -rf below is destructive and ROOTFS_DIR is overridable: refuse anything
# that is not an absolute path strictly inside the build directory.
BUILD_DIR="$(pwd)/build"
case "$ROOTFS_DIR" in
  "$BUILD_DIR"/?*) ;;
  *) echo "ERROR: ROOTFS_DIR ($ROOTFS_DIR) must be a subdirectory of $BUILD_DIR" >&2; exit 1 ;;
esac
case "$ROOTFS_DIR" in
  *..*) echo "ERROR: ROOTFS_DIR must not contain '..'" >&2; exit 1 ;;
esac

# The chroot runs arm64 binaries (and their children) via qemu-user; without a
# registered binfmt handler, nested exec calls fail with confusing errors.
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  echo "ERROR: qemu-aarch64 binfmt handler is not registered." >&2
  echo "Install qemu-user-static and binfmt-support, or run: sudo update-binfmts --enable qemu-aarch64" >&2
  exit 1
fi

mkdir -p "$(dirname "$IMG_FILE")"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

echo "Bootstrapping Debian ${RELEASE} arm64 root filesystem..."
sudo debootstrap --arch=arm64 --variant=minbase --foreign "$RELEASE" "$ROOTFS_DIR" "http://deb.debian.org/debian"

# QEMU static for chroot emulation.
sudo cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/"

# raspi-firmware installs into /boot/firmware; it must exist before apt runs.
sudo mkdir -p "$ROOTFS_DIR/boot/firmware"

# Pseudo-filesystems the kernel/initramfs postinst scripts expect.
sudo mount -t proc proc "$ROOTFS_DIR/proc"
sudo mount -t sysfs sys "$ROOTFS_DIR/sys"
sudo mount --bind /dev "$ROOTFS_DIR/dev"
sudo mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"

echo "Configuring Debian for Raspberry Pi 5..."
sudo chroot "$ROOTFS_DIR" /usr/bin/qemu-aarch64-static /bin/bash -c "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
RELEASE='${RELEASE}'

/debootstrap/debootstrap --second-stage

# Configure APT sources first so non-free-firmware is available to the installs below.
cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian \${RELEASE} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian \${RELEASE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security \${RELEASE}-security main contrib non-free non-free-firmware
EOF

apt-get update
apt-get install -y --no-install-recommends \\
  systemd-sysv \\
  dbus \\
  sudo \\
  iproute2 \\
  netbase \\
  openssh-server \\
  ca-certificates \\
  firmware-brcm80211 \\
  raspi-firmware \\
  linux-image-arm64 \\
  initramfs-tools

useradd -m -s /bin/bash -G sudo pi
printf 'pi:raspberry\nroot:raspberry\n' | chpasswd
# Force a password change on first login; the defaults above are public knowledge.
chage -d 0 pi
passwd -l root

systemctl enable ssh

cat > /etc/hostname <<EOF
pi5
EOF

cat > /etc/hosts <<EOF
127.0.0.1 localhost
127.0.1.1 pi5
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

cat > /etc/modules <<EOF
# /etc/modules: kernel modules to load at boot time.
brcmfmac
EOF

apt-get clean
"

# Pseudo-filesystems are no longer needed; unmount before copying the rootfs out.
sudo umount "$ROOTFS_DIR/dev/pts"
sudo umount "$ROOTFS_DIR/dev"
sudo umount "$ROOTFS_DIR/sys"
sudo umount "$ROOTFS_DIR/proc"

# Create disk image with a boot and root partition.
truncate -s "$IMAGE_SIZE" "$IMG_FILE"

sudo parted -s "$IMG_FILE" -- mklabel msdos
sudo parted -s "$IMG_FILE" -- unit MiB mkpart primary fat32 1 "$BOOT_SIZE"
sudo parted -s "$IMG_FILE" -- set 1 boot on
sudo parted -s "$IMG_FILE" -- unit MiB mkpart primary ext4 "$BOOT_SIZE" 100%

LOOP_DEVICE="$(sudo losetup --show -fP "$IMG_FILE")"
PART_BOOT="${LOOP_DEVICE}p1"
PART_ROOT="${LOOP_DEVICE}p2"

sudo mkfs.vfat -F 32 "$PART_BOOT"
sudo mkfs.ext4 -F "$PART_ROOT"

mkdir -p "$BOOT_MNT" "$ROOT_MNT"

sudo mount "$PART_ROOT" "$ROOT_MNT"
sudo mount "$PART_BOOT" "$BOOT_MNT"

sudo rsync -aHAX --delete --exclude '/boot/firmware/*' "$ROOTFS_DIR"/ "$ROOT_MNT"/

# The FAT partition IS /boot/firmware. Its contents go at the partition root,
# where the Pi 5 bootloader looks for config.txt, the .dtb files and start*.elf.
sudo rsync -aHAX --delete "$ROOTFS_DIR/boot/firmware"/ "$BOOT_MNT"/

BOOT_PARTUUID="$(sudo blkid -s PARTUUID -o value "$PART_BOOT")"
ROOT_PARTUUID="$(sudo blkid -s PARTUUID -o value "$PART_ROOT")"

sudo tee "$ROOT_MNT/etc/fstab" >/dev/null <<EOF
PARTUUID=${ROOT_PARTUUID}  /               ext4    defaults,noatime  0 1
PARTUUID=${BOOT_PARTUUID}  /boot/firmware  vfat    defaults          0 2
EOF

# raspi-firmware generates config.txt itself. Append only Pi 5 specifics, and
# leave its kernel/initramfs directives untouched.
sudo tee -a "$BOOT_MNT/config.txt" >/dev/null <<EOF

[pi5]
enable_uart=1
dtoverlay=vc4-kms-v3d
dtparam=audio=off
EOF

sudo tee "$BOOT_MNT/cmdline.txt" >/dev/null <<EOF
root=PARTUUID=${ROOT_PARTUUID} rw rootwait console=ttyAMA0,115200 console=tty1 rootfstype=ext4 fsck.repair=yes
EOF

sudo umount "$BOOT_MNT" "$ROOT_MNT"
sudo losetup -d "$LOOP_DEVICE"
LOOP_DEVICE=""

xz -T0 -c "$IMG_FILE" > "${IMG_FILE}.xz"

ls -lh "$IMG_FILE" "${IMG_FILE}.xz"
