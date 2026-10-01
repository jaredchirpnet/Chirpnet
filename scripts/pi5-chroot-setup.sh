#!/usr/bin/env bash
# Runs INSIDE the arm64 chroot (under qemu-user). Called by build-pi5-image.sh.
# Env: RELEASE, JLINK_MODULES, TEDGE_PACKAGES, TEDGE_REPO
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${RELEASE:?}" "${JLINK_MODULES:?}" "${TEDGE_PACKAGES:?}" "${TEDGE_REPO:?}"

/debootstrap/debootstrap --second-stage

# Don't let package postinst scripts try to start services inside the chroot.
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${RELEASE}-security main contrib non-free non-free-firmware
EOF

# --- Size: never pull optional packages, never unpack docs/man/locales -------
cat > /etc/apt/apt.conf.d/99-minimal <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
EOF
cat > /etc/dpkg/dpkg.cfg.d/99-minimal <<'EOF'
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/man/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/lintian/*
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/locale.alias
EOF

apt-get update
apt-get install -y \
  systemd-sysv systemd-timesyncd systemd-resolved dbus \
  sudo netbase openssh-server ca-certificates fdisk \
  firmware-brcm80211 raspi-firmware linux-image-arm64 initramfs-tools

# The Pi 5 DTB must be present, otherwise this kernel cannot boot the board.
if [ ! -f /boot/firmware/bcm2712-rpi-5-b.dtb ]; then
  echo "ERROR: bcm2712-rpi-5-b.dtb missing; ${RELEASE}'s kernel has no Raspberry Pi 5 support." >&2
  echo "Use a newer release (e.g. DEBIAN_RELEASE=trixie) or a backports kernel." >&2
  ls -R /boot/firmware >&2 || true
  exit 1
fi

# --- Users / ssh --------------------------------------------------------------
useradd -m -s /bin/bash -G sudo pi
printf 'pi:raspberry\n' | chpasswd
chage -d 0 pi          # force password change on first login
passwd -l root

# Host keys must be unique per device: generate them at first boot, not here.
mkdir -p /etc/systemd/system/ssh.service.d
cat > /etc/systemd/system/ssh.service.d/keygen.conf <<'EOF'
[Service]
ExecStartPre=/usr/bin/ssh-keygen -A
EOF

# --- Identity / network -------------------------------------------------------
echo pi5 > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1 localhost
127.0.1.1 pi5
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
echo brcmfmac > /etc/modules

mkdir -p /etc/systemd/network
cat > /etc/systemd/network/20-wired.network <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF

# --- Grow the root partition to fill the device on first boot -----------------
cat > /usr/local/sbin/growroot <<'EOF'
#!/bin/sh
set -eu
part="$(findmnt -no SOURCE /)"
name="$(basename "$part")"
disk="/dev/$(lsblk -no PKNAME "$part")"
num="$(cat "/sys/class/block/$name/partition")"
echo ', +' | sfdisk --no-reread --no-tell-kernel -N "$num" "$disk"
partx -u "$disk"
resize2fs "$part"
touch /var/lib/growroot.done
EOF
chmod +x /usr/local/sbin/growroot
cat > /etc/systemd/system/growroot.service <<'EOF'
[Unit]
Description=Grow root partition to fill the device
ConditionPathExists=!/var/lib/growroot.done
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/growroot

[Install]
WantedBy=multi-user.target
EOF

# --- thin-edge.io -------------------------------------------------------------
apt-get install -y curl gnupg
curl -1sLf "https://dl.cloudsmith.io/public/thinedge/${TEDGE_REPO}/setup.deb.sh" | bash
# shellcheck disable=SC2086
apt-get install -y ${TEDGE_PACKAGES}

# --- Smallest JRE: jlink a runtime with only the requested modules ------------
apt-get install -y default-jdk-headless
JDK_HOME="$(dirname "$(dirname "$(readlink -f /usr/bin/javac)")")"
"$JDK_HOME/bin/jlink" --add-modules "$JLINK_MODULES" \
  --strip-debug --no-header-files --no-man-pages --compress=2 \
  --output /opt/jre
# jlink does not carry Debian's cacerts over; TLS from Java needs it.
if [ -f /etc/ssl/certs/java/cacerts ]; then
  cp /etc/ssl/certs/java/cacerts /opt/jre/lib/security/cacerts
else
  echo "WARNING: no Java cacerts found; Java TLS will not trust any CA" >&2
fi
ln -s /opt/jre/bin/java /usr/local/bin/java
/opt/jre/bin/java -version

# Drop the build-only tools (and the full JDK/JRE) without touching tedge's deps.
apt-mark auto curl gnupg default-jdk-headless >/dev/null
apt-get autoremove --purge -y

# --- Trim kernel modules/firmware this device will never use ------------------
for d in /lib/modules/*/; do
  v="$(basename "$d")"
  for p in kernel/sound kernel/drivers/media kernel/drivers/staging \
           kernel/drivers/infiniband kernel/drivers/gpu/drm/amd \
           kernel/drivers/gpu/drm/nouveau kernel/drivers/gpu/drm/radeon \
           kernel/drivers/gpu/drm/i915 kernel/drivers/gpu/drm/xe; do
    rm -rf "${d}${p}"
  done
  depmod -a "$v"
done
# Keep only the Pi's own Wi-Fi chip (CYW43455) firmware.
find /lib/firmware/brcm /lib/firmware/cypress \( -type f -o -type l \) \
  ! -name '*43455*' -delete 2>/dev/null || true

# --- Enable services, final cleanup -------------------------------------------
systemctl enable ssh systemd-networkd systemd-resolved systemd-timesyncd growroot.service

apt-get clean
rm -f /usr/sbin/policy-rc.d
rm -rf /var/lib/apt/lists/* /var/cache/* /tmp/* /usr/share/man/* /usr/share/info/* /usr/share/lintian/*
find /var/log -type f -delete
find /usr/share/doc -type f ! -name copyright -delete
find /usr/share/doc -type d -empty -delete
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name locale.alias -exec rm -rf {} +
rm -f /etc/ssh/ssh_host_*
: > /etc/machine-id
rm -f /etc/resolv.conf
ln -s ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
