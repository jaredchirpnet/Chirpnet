#!/usr/bin/env bash
set -euo pipefail

ROOTFS_DIR="${ROOTFS_DIR:-$(pwd)/build/rootfs}"
IMG_FILE="${IMG_FILE:-$(pwd)/build/debian-pi5-bookworm.img}"
RELEASE="${DEBIAN_RELEASE:-bookworm}"
IMAGE_SIZE="${IMAGE_SIZE:-8G}"
BOOT_SIZE="${BOOT_SIZE:-256MiB}"

mkdir -p "$(dirname "$IMG_FILE")"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

echo "Bootstrapping Debian ${RELEASE} arm64 root filesystem..."
sudo debootstrap --arch=arm64 --variant=minbase --foreign "$RELEASE" "$ROOTFS_DIR" "http://deb.debian.org/debian"

# QEMU static for chroot emulation.
sudo cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/"

echo "Configuring Debian for Raspberry Pi 5..."
sudo chroot "$ROOTFS_DIR" /usr/bin/qemu-aarch64-static /bin/bash -lc '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

/debootstrap/debootstrap --second-stage

# Configure APT sources first to include non-free-firmware
cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
# deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
# deb http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

apt-get update
apt-get install -y --no-install-recommends \
  systemd-sysv \
  dbus \
  sudo \
  iproute2 \
  netbase \
  openssh-server \
  ca-certificates \
  firmware-brcm80211 \
  raspi-firmware \
  linux-image-arm64 \
  initramfs-tools

useradd -m -s /bin/bash -G sudo pi
printf "pi:raspberry\nroot:raspberry\n" | chpasswd

systemctl enable ssh

cat > /etc/hostname <<"EOF"
pi5
EOF

cat > /etc/hosts <<"EOF"
127.0.0.1 localhost
127.0.1.1 pi5
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

cat > /etc/modules <<"EOF"
# /etc/modules: kernel modules to load at boot time.
bcm2712
brcmfmac
EOF

apt-get clean
'

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

BOOT_MNT="$(pwd)/mnt/boot"
ROOT_MNT="$(pwd)/mnt/root"
mkdir -p "$BOOT_MNT" "$ROOT_MNT"

sudo mount "$PART_BOOT" "$BOOT_MNT"
sudo mount "$PART_ROOT" "$ROOT_MNT"

sudo rsync -aHAX --delete "$ROOTFS_DIR"/ "$ROOT_MNT"/

# Copy boot files to the FAT32 partition.
if [ -d "$ROOTFS_DIR/boot/firmware" ]; then
  sudo mkdir -p "$BOOT_MNT/firmware"
  sudo rsync -aHAX --delete "$ROOTFS_DIR/boot/firmware"/ "$BOOT_MNT/firmware"/
fi

if [ -d "$ROOTFS_DIR/boot" ]; then
  sudo rsync -aHAX --delete "$ROOTFS_DIR/boot"/ "$BOOT_MNT"/
fi

BOOT_PARTUUID="$(sudo blkid -s PARTUUID -o value "$PART_BOOT")"
ROOT_PARTUUID="$(sudo blkid -s PARTUUID -o value "$PART_ROOT")"

sudo tee "$ROOT_MNT/etc/fstab" >/dev/null <<EOF
PARTUUID=${ROOT_PARTUUID}  /               ext4    defaults,noatime  0 1
PARTUUID=${BOOT_PARTUUID}  /boot           vfat    defaults        0 2
EOF

sudo tee "$BOOT_MNT/config.txt" >/dev/null <<EOF
[pi5]
kernel=vmlinuz
arm_64bit=1
enable_uart=1
dtoverlay=vc4-kms-v3d
dtparam=audio=off
gpu_mem=16
cmdline=cmdline.txt
EOF

sudo tee "$BOOT_MNT/cmdline.txt" >/dev/null <<EOF
root=PARTUUID=${ROOT_PARTUUID} rw rootwait console=ttyAMA0,115200 console=tty1 rootfstype=ext4 fsck.repair=yes
EOF

sudo umount "$BOOT_MNT" "$ROOT_MNT"
sudo losetup -d "$LOOP_DEVICE"

xz -T0 -c "$IMG_FILE" > "${IMG_FILE}.xz"

ls -lh "$IMG_FILE" "${IMG_FILE}.xz"
