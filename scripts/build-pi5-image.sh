#!/usr/bin/env bash
# Builds a minimal Debian arm64 image for the Raspberry Pi 5 that runs
# thin-edge.io (tedge) and a jlink-minimised JRE.
#
# Env (all optional):
#   DEBIAN_RELEASE  Debian codename                       (default: trixie)
#   IMAGE_SIZE      total image size, e.g. 2G, or "auto"  (default: auto = fit contents)
#   BOOT_SIZE       FAT partition size in MiB, or "auto"  (default: auto)
#   JLINK_MODULES   comma-separated JDK modules for the JRE (default: java.base)
#   TEDGE_PACKAGES  tedge apt packages to install          (default: tedge-minimal)
#   TEDGE_REPO      Cloudsmith repo name                   (default: tedge-release)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="${DEBIAN_RELEASE:-trixie}"
ROOTFS_DIR="${ROOTFS_DIR:-$(pwd)/build/rootfs}"
IMG_FILE="${IMG_FILE:-$(pwd)/build/debian-pi5-${RELEASE}.img}"
IMAGE_SIZE="${IMAGE_SIZE:-auto}"
BOOT_SIZE="${BOOT_SIZE:-auto}"
JLINK_MODULES="${JLINK_MODULES:-java.base}"
TEDGE_PACKAGES="${TEDGE_PACKAGES:-tedge-minimal}"
TEDGE_REPO="${TEDGE_REPO:-tedge-release}"

BOOT_MNT="$(pwd)/mnt/boot"
ROOT_MNT="$(pwd)/mnt/root"
LOOP_DEVICE=""

cleanup() {
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

sudo cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/"
sudo mkdir -p "$ROOTFS_DIR/boot/firmware"

sudo mount -t proc proc "$ROOTFS_DIR/proc"
sudo mount -t sysfs sys "$ROOTFS_DIR/sys"
sudo mount --bind /dev "$ROOTFS_DIR/dev"
sudo mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"

echo "Configuring Debian for Raspberry Pi 5..."
sudo install -m 0755 "$SCRIPT_DIR/pi5-chroot-setup.sh" "$ROOTFS_DIR/tmp/pi5-chroot-setup.sh"
sudo chroot "$ROOTFS_DIR" /usr/bin/qemu-aarch64-static /usr/bin/env \
  RELEASE="$RELEASE" JLINK_MODULES="$JLINK_MODULES" \
  TEDGE_PACKAGES="$TEDGE_PACKAGES" TEDGE_REPO="$TEDGE_REPO" \
  /bin/bash /tmp/pi5-chroot-setup.sh
sudo rm -f "$ROOTFS_DIR/tmp/pi5-chroot-setup.sh"

sudo umount "$ROOTFS_DIR/dev/pts"
sudo umount "$ROOTFS_DIR/dev"
sudo umount "$ROOTFS_DIR/sys"
sudo umount "$ROOTFS_DIR/proc"

# --- Size the image from what is actually in the rootfs -----------------------
BOOT_USED_MIB="$(sudo du -sm "$ROOTFS_DIR/boot/firmware" | cut -f1)"
TOTAL_USED_MIB="$(sudo du -sxm "$ROOTFS_DIR" | cut -f1)"

if [ "$BOOT_SIZE" = auto ]; then
  BOOT_MIB=$(( BOOT_USED_MIB * 130 / 100 + 8 ))
  [ "$BOOT_MIB" -lt 64 ] && BOOT_MIB=64     # FAT32 needs >= ~33 MiB
else
  BOOT_MIB="${BOOT_SIZE%MiB}"
fi
BOOT_END_MIB=$(( 1 + BOOT_MIB ))

if [ "$IMAGE_SIZE" = auto ]; then
  # 15% headroom plus ~64 MiB for the ext4 journal/metadata. The partition is
  # grown to the full device on first boot (growroot.service).
  ROOT_MIB=$(( (TOTAL_USED_MIB - BOOT_USED_MIB) * 115 / 100 + 64 ))
  [ "$ROOT_MIB" -lt 256 ] && ROOT_MIB=256
  IMAGE_TRUNCATE="$(( BOOT_END_MIB + ROOT_MIB ))M"
else
  IMAGE_TRUNCATE="$IMAGE_SIZE"
fi
echo "rootfs: ${TOTAL_USED_MIB} MiB used (boot ${BOOT_USED_MIB} MiB); image: ${IMAGE_TRUNCATE}, boot partition: ${BOOT_MIB} MiB"

truncate -s "$IMAGE_TRUNCATE" "$IMG_FILE"

sudo parted -s "$IMG_FILE" -- mklabel msdos
sudo parted -s "$IMG_FILE" -- unit MiB mkpart primary fat32 1 "$BOOT_END_MIB"
sudo parted -s "$IMG_FILE" -- set 1 boot on
sudo parted -s "$IMG_FILE" -- unit MiB mkpart primary ext4 "$BOOT_END_MIB" 100%

LOOP_DEVICE="$(sudo losetup --show -fP "$IMG_FILE")"
PART_BOOT="${LOOP_DEVICE}p1"
PART_ROOT="${LOOP_DEVICE}p2"

sudo mkfs.vfat -F 32 -n BOOT "$PART_BOOT"
sudo mkfs.ext4 -F -m 0 -L rootfs "$PART_ROOT"

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

xz -9e -T0 -c "$IMG_FILE" > "${IMG_FILE}.xz"

ls -lh "$IMG_FILE" "${IMG_FILE}.xz"
