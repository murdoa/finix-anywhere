#!/usr/bin/env bash
set -euo pipefail

cli=$(realpath "${1:?Usage: cli.sh <finix-anywhere executable>}")
work=$(mktemp -d -t finix-anywhere-cli.XXXXXXXXXX)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
export HOME="$work/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_STATE_HOME="$HOME/.local/state"
export NIX_REMOTE="local?root=$work/nix-store"
export SSH_GUARD_LOG="$work/ssh-attempted"
mkdir -p "$HOME" "$work/bin" "$work/system" "$work/flake"

# The guard stops the real CLI at its first SSH call. No machine can be modified.
printf '#!%s\n' "$(command -v bash)" >"$work/bin/ssh"
cat >>"$work/bin/ssh" <<'SH'
printf 'SSH attempted\n' >"$SSH_GUARD_LOG"
exit 91
SH
chmod +x "$work/bin/ssh"
export PATH="$work/bin:$PATH"

runCase() {
  local expected=$1 status=0
  shift
  rm -f "$SSH_GUARD_LOG"
  "$cli" "$@" >"$work/output" 2>&1 || status=$?
  case "$expected" in
  reject)
    if [[ $status != 1 || -e $SSH_GUARD_LOG ]]; then
      cat "$work/output" >&2
      echo "Expected rejection before SSH (status=$status): $*" >&2
      exit 1
    fi
    ;;
  accept)
    if [[ $status != 91 || ! -e $SSH_GUARD_LOG ]]; then
      cat "$work/output" >&2
      echo "Expected preflight to reach the SSH guard (status=$status): $*" >&2
      exit 1
    fi
    ;;
  esac
}

runCase reject --vm-test
runCase reject --generate-hardware-config nixos-generate-config "$work/hardware.nix"

printf 'finix\n' >"$work/system/nixos-version"
touch "$work/disko" "$work/system/kernel" "$work/system/initrd" "$work/system/init" "$work/system/activate"
cat >"$work/valid-boot.json" <<'JSON'
{
  "org.nixos.bootspec.v1": { "system": "x86_64-linux" },
  "org.finix-anywhere.v1": {
    "bootloader": "limine",
    "bootloaderInstall": "/nix/store/test-bootloader/install",
    "tmpfiles": "/nix/store/test-finit/libexec/finit/tmpfiles",
    "hostKeys": ["/var/lib/sshd/ssh_host_ed25519_key"]
  }
}
JSON
cp "$work/valid-boot.json" "$work/system/boot.json"
storeArgs=(--store-paths "$work/disko" "$work/system" --build-on remote --target-host example.invalid)

# A Finix closure needs boot.json, not the NixOS-only /system file.
runCase accept "${storeArgs[@]}"
runCase accept "${storeArgs[@]}" --copy-host-keys
printf '25.11\n' >"$work/system/nixos-version"
runCase reject "${storeArgs[@]}"
printf 'finix\n' >"$work/system/nixos-version"
rm "$work/system/kernel"
runCase reject "${storeArgs[@]}"
touch "$work/system/kernel"

jq 'del(."org.finix-anywhere.v1")' "$work/valid-boot.json" >"$work/system/boot.json"
runCase reject "${storeArgs[@]}"
jq '."org.finix-anywhere.v1".bootloader = "none"' "$work/valid-boot.json" >"$work/system/boot.json"
runCase reject "${storeArgs[@]}"
jq 'del(."org.finix-anywhere.v1".bootloaderInstall)' "$work/valid-boot.json" >"$work/system/boot.json"
runCase reject "${storeArgs[@]}"
jq 'del(."org.finix-anywhere.v1".tmpfiles)' "$work/valid-boot.json" >"$work/system/boot.json"
runCase reject "${storeArgs[@]}"
jq 'del(."org.nixos.bootspec.v1".system)' "$work/valid-boot.json" >"$work/system/boot.json"
runCase reject "${storeArgs[@]}"

jq '."org.finix-anywhere.v1".hostKeys = []' "$work/valid-boot.json" >"$work/system/boot.json"
runCase reject "${storeArgs[@]}" --copy-host-keys
jq '."org.finix-anywhere.v1".hostKeys = ["/etc/ssh/ssh_host_rsa_key"]' "$work/valid-boot.json" >"$work/system/boot.json"
runCase reject "${storeArgs[@]}" --copy-host-keys
jq '."org.finix-anywhere.v1".hostKeys = ["/../ssh_host_ed25519_key"]' "$work/valid-boot.json" >"$work/system/boot.json"
runCase reject "${storeArgs[@]}" --copy-host-keys
cp "$work/valid-boot.json" "$work/system/boot.json"
runCase reject "${storeArgs[@]}" --copy-host-keys --phases kexec

# Real evaluation exercises Finix's option shape and forces toplevel assertions,
# including when builds are delegated remotely. No derivation is built.
cat >"$work/flake/flake.nix" <<'NIX'
{
  outputs = { self }:
    let
      config = {
        nixpkgs.pkgs.stdenv.hostPlatform.system = "x86_64-linux";
        system.build.toplevel = builtins.derivation {
          name = "finix-cli-preflight";
          system = "x86_64-linux";
          builder = "/bin/sh";
        };
        boot.bootspec.extensions."org.finix-anywhere.v1" = {
          bootloader = "limine";
          bootloaderInstall = "/nix/store/test-bootloader/install";
          tmpfiles = "/nix/store/test-finit/libexec/finit/tmpfiles";
          hostKeys = [ "/var/lib/sshd/ssh_host_ed25519_key" ];
        };
      };
    in {
      nixosConfigurations.valid = { inherit config; };
      nixosConfigurations.invalid.config = config // {
        system.build.toplevel = assert false; config.system.build.toplevel;
      };
      nixosConfigurations.noMarker.config = config // {
        boot.bootspec.extensions = {};
      };
    };
}
NIX
runCase accept --flake "path:$work/flake#valid" --build-on remote --target-host example.invalid
runCase reject --flake "path:$work/flake#invalid" --build-on remote --target-host example.invalid
runCase reject --flake "path:$work/flake#noMarker" --build-on remote --target-host example.invalid

printf 'CLI preflight safety checks passed\n'
