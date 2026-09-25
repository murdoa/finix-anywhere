# Quickstart: Finix on an x86_64 UEFI target

This guide uses `examples/flake.nix` and `examples/target.nix` in the repository.
Read the [requirements and safety checks](requirements.md) first. The default deployment
**destroys the disks selected by disko**. Have verified backups and console access.

The example uses Limine, GPT, a FAT EFI System Partition, an ext4 root, DHCP, and
public-key-only root SSH access. It is not a hardware detector or a universal
Finix installation configuration.

## 1. Prepare the checkout and your public key

Run commands from the root of this repository. The explicit `path:` flake URLs
include local files even when they are not tracked by Git. Review the checkout's
contents first; path flakes copy their source into the Nix store. Never place
private keys or other secrets inside the checkout.

Copy a **real public key** into the example:

```sh
cp "$HOME/.ssh/id_ed25519.pub" examples/authorized_keys
```

Use the public half of the key with which you intend to log into the installed
system. If your key is elsewhere, adjust the command. No authorized key is shipped
and the configuration requires this file. `examples/authorized_keys` is ignored
by Git to avoid accidentally committing deployment-specific credentials; the
explicit `path:.?dir=examples` invocation includes it. If you maintain a separate
Git-backed deployment flake, deliberately track its public-key file or arrange
another explicit source for it. Do not substitute a private key.

The example's `finix-anywhere` input points to `path:..`, this checkout. If you
copy the example elsewhere, change that input to your fork's checkout or pinned
repository rather than leaving a broken relative path.

Keep `?dir=examples` when invoking this nested example: it includes the repository
root so the relative `path:..` input resolves inside the same source tree.

## 2. Review and edit the target configuration

In `examples/flake.nix`, change `disk = "/dev/vda"` to the intended **whole disk**,
preferably a stable `/dev/disk/by-id/…` path verified on the target. Every partition
on that disk will be replaced by the default run. `/dev/vda` is a VM example, not
a safe guess for a physical machine.

Review `examples/target.nix` and adapt:

- Kernel/initrd modules and other hardware settings for the machine.
- Hostname and network configuration. The example enables
  `services.dhcpcd.enable` and brings up loopback with ifupdown-ng. Supply the
  correct Finix network configuration if DHCP is not appropriate; installed
  networking is independent of the rescue network.
- The EFI System Partition, root filesystem, and Limine configuration. Keep UEFI
  firmware enabled for this layout.
- SSH access. The public key file supplies root's authorized keys at
  `/etc/ssh/authorized_keys/root`; password authentication is disabled. The example
  uses `environment.etc` mode `"0600"` to copy a root-owned file, not symlink it.
  Keep this explicit mode: OpenSSH's `StrictModes` follows store symlinks and
  rejects the group-writable `/nix/store` directory. Do not disable `StrictModes`
  or change Nix store permissions to bypass this check. Configure other real
  accounts or credentials deliberately if required.
- Login shells. The example imports and enables Finix's Bash module because
  root's configured shell resolves through the system profile. The deployment
  module does not inject a shell into arbitrary target configurations.

The flake calls `finix.lib.finixSystem` and exports
`nixosConfigurations.target`. It imports
`finix-anywhere.nixosModules.default`, which combines the disko integration with
this fork's deployment assertions and metadata. Keep that import. A stock NixOS
configuration or generated NixOS hardware module is not a replacement.

## 3. Verify rescue access and build the paths

Use ordinary SSH to inspect the existing target before invoking the installer:

```sh
ssh root@TARGET_IP
```

Replace `TARGET_IP` everywhere with the verified target. Inspect its disks with
`lsblk`, confirm UEFI mode, and check the RAM installer's networking requirements.
The default path starts from a systemd Linux host such as stock Ubuntu 24.04 and
uses `kexec` to boot Finix in RAM. No NixOS installer step is required. Kernel
lockdown or a disabled kexec syscall prevents this path.

**Do not rely on installer SSH to verify the host:** its inherited options disable
strict host-key verification and ignore the persistent known-hosts database.
Verify identity independently and use a trusted network.

Back on the deployment host, build both outputs without connecting to the target:

```sh
nix build --no-link 'path:.?dir=examples#nixosConfigurations.target.config.system.build.diskoScript' -L
nix build --no-link 'path:.?dir=examples#nixosConfigurations.target.config.system.build.toplevel' -L
```

These builds establish that the outputs can be built, not that the hardware will
boot. Review the generated disko script and your configuration before proceeding.
The example's dependencies follow the pinned Finix/nixpkgs inputs of this checkout.

## 4. Deploy

Only after reviewing the disk, credentials, network, and recovery plan:

```sh
nix run path:.#finix-anywhere -- \
  --flake 'path:.?dir=examples#target' \
  --target-host root@TARGET_IP
```

Use `-i /path/to/private_key` to choose the key used for the **existing** SSH
connection. That option does not provision an authorized key in the new system.
The existing host can also be addressed using an account with supported privilege
elevation; ensure root access in rescue will work.

The normal sequence is native Finix RAM boot, destructive disko, Finix activation
and bootloader installation, then reboot into the installed Finix system.

For a host unable to build x86_64 Linux locally, select `--build-on remote` and
ensure the rescue environment has sufficient RAM, storage, and cache/build
network access. See the [reference](reference.md) for prebuilt `--store-paths`,
phase selection, extra files, host-key preservation, and cache options.

## 5. Confirm the installed system

An installer success message does not certify boot readiness. Watch the console
for a successful Finix/Limine boot, confirm the expected IP and routes, then log
in using the public key you configured. Verify root and EFI mounts and the
services you need before considering the machine commissioned.

Without `--copy-host-keys`, the installed system may have a different SSH host
identity. Verify a new fingerprint through a trusted console rather than blindly
removing a known-hosts warning. `--copy-host-keys` preserves only the supported
ed25519 identity mapping described in the reference; it does not configure user
login keys.

## Repository integration check

For a normal Git checkout containing the project files:

```sh
nix build .#checks.x86_64-linux.installation -L
```

If files are not yet tracked by Git, use
`nix build path:.#checks.x86_64-linux.installation -L` instead. This exercises the
repository's installation scenario on an appropriate x86_64 Linux VM-test
builder. It is not the unsupported upstream `--vm-test` interface and does not
validate an arbitrary machine configuration. No passing result is implied by
these instructions.
