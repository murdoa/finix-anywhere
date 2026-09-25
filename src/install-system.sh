#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'finix-anywhere: %s\n' "$*" >&2
  exit 1
}

is_store_path() {
  [[ $1 =~ ^/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[a-zA-Z0-9+._?=-]+(/[a-zA-Z0-9+._?=-]+)*$ && /$1/ != */../* && /$1/ != */./* ]]
}

# This function runs only in the child mount/UTS namespace. Activation is not a
# sandbox: /dev and kernel state are still shared with the running installer.
install_in_namespace() {
  set -euo pipefail
  mount --make-rprivate /

  system=$1
  bootloader_install=$2
  tmpfiles=$3
  chroot_command=$(command -v chroot)
  namespace_mounts=()
  kernel_knob_paths=()
  kernel_knob_values=()

  restore_kernel_knobs() {
    local status=0 i
    for ((i = 0; i < ${#kernel_knob_paths[@]}; i++)); do
      if ! printf '%s\n' "${kernel_knob_values[i]}" >"${kernel_knob_paths[i]}"; then
        printf 'finix-anywhere: cannot restore %s\n' "${kernel_knob_paths[i]}" >&2
        status=1
      fi
    done
    kernel_knob_paths=()
    kernel_knob_values=()
    return "$status"
  }

  # shellcheck disable=SC2329
  # Invoked by the EXIT trap in the exported namespace function.
  cleanup() {
    local status=$? i
    trap - EXIT HUP INT TERM
    if ! restore_kernel_knobs; then
      if ((status == 0)); then status=1; fi
    fi
    for ((i = ${#namespace_mounts[@]} - 1; i >= 0; i--)); do
      if ! umount --recursive "${namespace_mounts[i]}"; then
        printf 'finix-anywhere: cannot unmount %s\n' "${namespace_mounts[i]}" >&2
        if ((status == 0)); then status=1; fi
      fi
    done
    exit "$status"
  }

  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  mkdir -p /mnt/dev /mnt/proc /mnt/sys /mnt/run /mnt/tmp /mnt/etc
  chmod 1777 /mnt/tmp
  for directory in dev proc sys; do
    mount --rbind "/$directory" "/mnt/$directory"
    namespace_mounts+=("/mnt/$directory")
    mount --make-rslave "/mnt/$directory"
  done
  # Never expose the installer's /run (including its service control sockets) or
  # bind its /nix over the target store. /run/current-system must stay private.
  mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /mnt/run
  namespace_mounts+=(/mnt/run)

  run_in_target() {
    env -i \
      HOME=/root USER=root LOGNAME=root LANG=C NIX_REMOTE=local \
      PATH="$system/sw/bin:/bin:/sbin:/usr/bin:/usr/sbin" \
      "$chroot_command" /mnt "$@"
  }

  # Finix's modprobe and mdevd activation snippets write these live-kernel knobs.
  # Save before activation and restore immediately afterward, also on failure.
  for knob in \
    /proc/sys/kernel/modprobe \
    /proc/sys/kernel/hotplug \
    /sys/module/firmware_class/parameters/path; do
    if [[ -e $knob ]]; then
      value=$(cat "$knob")
      kernel_knob_paths+=("$knob")
      kernel_knob_values+=("$value")
    fi
  done

  run_in_target "$system/activate"
  restore_kernel_knobs
  run_in_target "$tmpfiles" --create
  run_in_target "$bootloader_install" "$system"
  sync
}

[[ $# == 1 ]] || fail 'usage: install-system.sh /nix/store/HASH-finix-system'
[[ $EUID == 0 ]] || fail 'installation requires root'
system=$1
[[ $system =~ ^/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[a-zA-Z0-9+._?=-]+$ ]] || fail 'expected a logical system store path'
[[ ! -L /mnt && ! /mnt -ef / ]] || fail '/mnt must be the target root, not the running system'
mountpoint -q /mnt || fail '/mnt is not a mounted target root'

# These paths are used before chroot. Refuse symlinks that could redirect writes
# or mounts into the live installer; target profile symlinks themselves are valid.
for directory in \
  /mnt/dev /mnt/proc /mnt/sys /mnt/run /mnt/tmp /mnt/etc \
  /mnt/nix /mnt/nix/store /mnt/nix/var /mnt/nix/var/nix /mnt/nix/var/nix/profiles; do
  [[ ! -L $directory ]] || fail "target directory is a symlink: $directory"
done
[[ ! /mnt/nix/store -ef /nix/store ]] || fail 'target and installer must not share the Nix store'
[[ -d /mnt$system && ! -L /mnt$system && -x /mnt$system/activate && -f /mnt$system/boot.json ]] || fail 'the target Finix system closure is missing or invalid'
[[ $(cat "/mnt$system/nixos-version") == finix ]] || fail 'the target closure is not a Finix system'

metadata=$(jq -er --arg system "$system" '
  ."org.finix-anywhere.v1" as $deployment |
  if ."org.nixos.bootspec.v1".toplevel == $system
    and ($deployment.bootloader | type == "string" and length > 0 and . != "none")
    and ($deployment.bootloaderInstall | type == "string")
    and ($deployment.tmpfiles | type == "string")
  then [$deployment.bootloaderInstall, $deployment.tmpfiles] | @tsv
  else error("missing or invalid Finix installation metadata")
  end
' "/mnt$system/boot.json")
IFS=$'\t' read -r bootloader_install tmpfiles <<<"$metadata"
is_store_path "$bootloader_install" || fail 'invalid bootloaderInstall store path'
is_store_path "$tmpfiles" || fail 'invalid tmpfiles store path'

# The bootloader enumerates Nix profile generations, not just the toplevel path.
# --store /mnt uses the already registered target closure and target store DB.
mkdir -p /mnt/nix/var/nix/profiles
env -u NIX_REMOTE -u NIX_CONFIG -u NIX_USER_CONF_FILES -u TMPDIR \
  nix-env --store /mnt --option build-users-group '' \
  -p /mnt/nix/var/nix/profiles/system --set "$system"

export -f install_in_namespace
unshare --fork --mount --uts -- "$BASH" -c 'install_in_namespace "$@"' \
  finix-install "$system" "$bootloader_install" "$tmpfiles"
