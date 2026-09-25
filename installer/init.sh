#!@shell@
set -euo pipefail
export PATH=@bootstrapPath@
export HOME=/root
export USER=root LOGNAME=root
export NIX_REMOTE=local
umask 022

mkdir -p /dev /proc /sys /run /tmp /etc /root /mnt
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
trap 'echo "finix-installer: RAM bootstrap failed; entering emergency shell"; exec @shell@ -i' ERR
mount -t tmpfs -o mode=0755,nosuid,nodev,size=10% tmpfs /run
chmod 1777 /tmp

mkdir -p /nix/var/nix/{db,profiles,gcroots} /var/lib/sshd /var/lib/finix-installer
chmod 1775 /nix/store
chown 0:@nixbldGid@ /nix/store
# Registration is part of the image, not a bind mount of the old host's store.
# Run locally before activation starts the native multi-user Nix daemon.
# Nix resolves the invoking uid even before Finix has created the real users.
printf 'root:x:0:0:root:/root:@shell@\n' > /etc/passwd
printf 'root:x:0:\n' > /etc/group
nix-store --option build-users-group '' --load-db < /registration
ln -s @system@ /nix/var/nix/gcroots/finix-installer
rm /registration /etc/passwd /etc/group

if [[ -d /finix-secrets ]]; then
  install -d -m 0700 /root/.ssh
  install -m 0600 /finix-secrets/authorized_keys /root/.ssh/authorized_keys
  install -m 0600 /finix-secrets/ssh_host_ed25519_key /var/lib/sshd/ssh_host_ed25519_key
  if [[ -d /finix-secrets/network ]]; then
    mv /finix-secrets/network /var/lib/finix-installer/network
  fi
  if [[ -s /finix-secrets/resolv.conf ]]; then
    install -m 0644 /finix-secrets/resolv.conf /etc/resolv.conf
  fi
  rm -rf /finix-secrets
fi

# Nix build sandboxes use pivot_root, which cannot pivot away from the kernel's
# initial rootfs. Move to an ordinary tmpfs mount before starting the real init.
# switch_root deletes the old unpacked image after the copy.
mkdir /newroot
mount -t tmpfs -o mode=0755,size=90% tmpfs /newroot
cp -a /nix /etc /root /var /newroot/
mkdir -p /newroot/{dev,proc,sys,run,tmp,mnt}
chmod 1777 /newroot/tmp
for directory in dev proc sys run; do
  mount --move "/$directory" "/newroot/$directory"
done

# finix-setup derives systemConfig from argv[0], not the resolved executable.
unset NIX_REMOTE
exec switch_root /newroot @system@/init
