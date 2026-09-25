#!/bin/sh
# shellcheck disable=SC2016
# Awk programs and the detached child shell intentionally receive literal variables.
set -eu
umask 077
bundle=${0%/*}
bb() { "$bundle/busybox" "$@"; }
fail() { printf 'finix-installer: %s\n' "$*" >&2; exit 1; }

extra_flags=
while [ "$#" -gt 0 ]; do
  case $1 in
    --kexec-extra-flags)
      [ "$#" -ge 2 ] || fail '--kexec-extra-flags requires a string'
      extra_flags=$2
      shift 2
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[ "$(bb id -u)" = 0 ] || fail 'run as root'
# Ubuntu 24.04 supplies both. Neither is taken from an installed Nix store.
ip=$(command -v ip) || fail 'iproute2 ip is required on the source host'
systemctl=$(command -v systemctl) || fail 'systemctl is required for a clean source-host shutdown'
[ -d /run/systemd/system ] || fail 'the source host must run systemd for a clean kexec shutdown'
[ "$(bb uname -m)" = "$(bb cat "$bundle/architecture")" ] || fail 'image architecture does not match the running host'

work=$(bb mktemp -d /tmp/finix-installer.XXXXXXXX)
trap 'bb rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
secrets=$work/overlay/finix-secrets
bb mkdir -p "$secrets/network"
: > "$secrets/authorized_keys"
for keyfile in /root/.ssh/authorized_keys /root/.ssh/authorized_keys2; do
  if [ -s "$keyfile" ]; then
    bb cat "$keyfile" >> "$secrets/authorized_keys"
    printf '\n' >> "$secrets/authorized_keys"
  fi
done
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  home=$(bb awk -F: -v user="$SUDO_USER" '$1 == user { print $6; exit }' /etc/passwd)
  if [ -n "$home" ] && [ -s "$home/.ssh/authorized_keys" ]; then
    bb cat "$home/.ssh/authorized_keys" >> "$secrets/authorized_keys"
    printf '\n' >> "$secrets/authorized_keys"
  fi
fi
[ -s "$secrets/authorized_keys" ] || fail 'no root/sudo-user authorized_keys found; custom AuthorizedKeysFile/Command configurations are not supported'
[ -s /etc/ssh/ssh_host_ed25519_key ] || fail 'source /etc/ssh/ssh_host_ed25519_key is required for host-key continuity'
bb cp /etc/ssh/ssh_host_ed25519_key "$secrets/ssh_host_ed25519_key"
bb chmod 0600 "$secrets/authorized_keys" "$secrets/ssh_host_ed25519_key"

# Only the standard local/main/default rules are supported. Restoring addresses
# while silently discarding policy routing could strand the SSH connection.
for family in 4 6; do
  "$ip" -"$family" rule show > "$work/rules"
  if bb grep -Ev '^[[:space:]]*(0:[[:space:]]+from all lookup local|32766:[[:space:]]+from all lookup main|32767:[[:space:]]+from all lookup default)[[:space:]]*$' "$work/rules"; then
    fail 'policy routing is not supported by the RAM network handoff'
  fi
done
for device in /sys/class/net/*; do
  interface=${device##*/}
  [ "$interface" != lo ] || continue
  "$ip" -o address show dev "$interface" scope global > "$work/addresses"
  [ -s "$work/addresses" ] || continue
  [ -e "$device/device" ] || fail "addressed virtual interface $interface: bridges, bonds, VLANs and tunnels are not supported"
  [ ! -d "$device/wireless" ] || fail "Wi-Fi interface $interface is not supported"
  [ "$(bb cat "$device/type")" = 1 ] || fail "non-Ethernet interface $interface is not supported"
  mac=$(bb cat "$device/address")
  saved=$secrets/network/$mac
  bb mkdir "$saved"
  bb cp "$device/mtu" "$saved/mtu"
  "$ip" -j address show dev "$interface" > "$saved/addresses.json"
  "$ip" -j -4 route show table main dev "$interface" > "$saved/routes4.json"
  "$ip" -j -6 route show table main dev "$interface" > "$saved/routes6.json"
done
# resolved's stub address is not usable after boot. Preserve its upstream list.
resolver=/etc/resolv.conf
if [ -s /run/systemd/resolve/resolv.conf ]; then
  resolver=/run/systemd/resolve/resolv.conf
fi
if [ -r "$resolver" ]; then
  bb awk '$1 == "nameserver" && $2 !~ /^127\./ && $2 != "::1" { print }
          $1 == "search" || $1 == "domain" || $1 == "options" { print }' "$resolver" > "$secrets/resolv.conf"
fi

# Concatenated gzip members avoid the alignment requirement for an uncompressed
# newc archive following a compressed member.
bb cp "$bundle/initrd" "$work/initrd"
(cd "$work/overlay" && bb find finix-secrets -print0 | bb cpio -o -0 -H newc | bb gzip -1) >> "$work/initrd"
params=$(bb cat "$bundle/kernel-params")
# Retain consoles, never Ubuntu root/resume/init arguments or its init system.
set -f
for parameter in $(bb cat /proc/cmdline); do
  case $parameter in console=*) params="$params $parameter" ;; esac
done
# Flags are whitespace-separated arguments, not shell code; never eval input.
# shellcheck disable=SC2086
"$bundle/kexec" --kexec-syscall-auto -l "$bundle/kernel" --initrd="$work/initrd" --command-line="$params" $extra_flags

# A single --force asks PID1 to perform the shutdown directly, including process
# termination, sync and unmounts. systemd 255 sees the already-loaded image and
# falls back to reboot(RB_KEXEC) if its own /usr/sbin/kexec is not installed.
# Detach all SSH descriptors before the delay; a successful caller may exit now.
bb setsid "$bundle/busybox" sh -c '
  trap "" HUP
  "$1" sleep 3
  exec "$2" --force kexec
' finix-kexec "$bundle/busybox" "$systemctl" </dev/null >/var/log/finix-kexec.log 2>&1 &
printf 'machine will boot into finix\n'
