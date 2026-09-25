# finix-anywhere

Install [Finix](https://github.com/finix-community/finix) over SSH, straight from
Ubuntu. Uses a native Finix RAM installer and disko—no NixOS installer required.

**The default run erases the configured disks.** Back up the target, check disk
paths, and arrange console access before starting.

**SSH host-key verification is disabled during deployment.** Verify the target
independently and use a trusted network.

## How it works

1. Connect to the existing machine over SSH with root privileges.
2. Build and boot the native Finix RAM installer with `kexec`, or reuse one already
   running. Remote builds bootstrap Nix directly on the source OS when necessary.
3. Run the target's disko script to prepare its disks.
4. Copy the Finix system closure, create its system profile, activate it, and
   install its bootloader in the mounted target.
5. Boot the installed Finix system.

**Ubuntu → Finix in RAM → installed Finix**

Export your Finix configuration as `nixosConfigurations.<name>` and import
`finix-anywhere.nixosModules.default` for disko and bootloader integration.

## Start here

- [Requirements and safety checks](docs/requirements.md)
- [Quickstart](docs/quickstart.md), using the [example flake](examples/flake.nix)
- [CLI and deployment reference](docs/reference.md)

The tested layout is **UEFI + Limine + GPT + ext4**, with an EFI System Partition.
Coverage includes automated x86_64 VM tests and a manual ARM64 deployment on a
Hetzner CAX11. Other layouts are untested. Supply a Finix configuration;
`--vm-test` and NixOS hardware-configuration generation are unsupported.

From a checkout, after configuring the disk and SSH public key in the
[quickstart](docs/quickstart.md):

```sh
nix run path:.#finix-anywhere -- --flake 'path:.?dir=examples#target' --target-host root@TARGET_IP
```

## Development

Run the CLI and installation checks on an x86_64 Linux builder with KVM:

```sh
nix build path:.#checks.x86_64-linux.cli path:.#checks.x86_64-linux.installation -L
```

The installation test boots the native RAM installer with kexec, runs a sandboxed
Nix build, installs Finix, and cold-boots the disk twice under UEFI. It checks
Finit as PID 1, SSH authentication, host-key preservation, system profiles,
credentials, file permissions, and persistence. The source VM uses NixOS for the
test harness; the installed system boots without a shared Nix store.

The ARM64 cloud run covered stock Ubuntu 24.04.4, remote builds, native RAM boot,
disk installation, and a further reboot with SSH and persistent data intact.

## Provenance and license

[MIT licensed](LICENSE). Forked from
[nix-community/nixos-anywhere](https://github.com/nix-community/nixos-anywhere/tree/da83557d8b0bce57a52371b888ffd6d58724e55c).
Upstream copyright © 2022 Numtide.
