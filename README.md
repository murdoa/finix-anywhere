# finix-anywhere

Install [Finix](https://github.com/finix-community/finix) over SSH using a native
Finix RAM installer and disko. This is a focused fork of
[nixos-anywhere](https://github.com/nix-community/nixos-anywhere), not a claim that
all upstream NixOS configurations or deployment integrations work with Finix.

**Destructive:** the default run partitions and formats the configured disks,
installs the system, and reboots. Back up the target, verify its identity and disk
paths, and arrange console or rescue access before starting.

**SSH security:** inherited SSH behavior disables strict host-key checking and
uses `/dev/null` as the known-hosts file. The installer does not authenticate the
server's identity through a persistent known-hosts database. Use a trusted network
and verify the target independently; do not treat successful SSH as proof of its
identity.

## How it works

1. Connect to the existing machine over SSH with root privileges.
2. Build and boot the native Finix RAM installer with `kexec`, or reuse one already
   running. Remote builds bootstrap Nix directly on the source OS when necessary.
3. Run the target's disko script to prepare its disks.
4. Copy the Finix system closure, create its system profile, activate it, and
   install its bootloader in the mounted target.
5. Boot the installed Finix system.

The default path is **Ubuntu → Finix in RAM → installed Finix**; no NixOS installer
is involved. Finix uses the `nixosConfigurations.<name>` flake output convention.
Each deployment must import this fork's `nixosModules.default`, which combines
disko with the Finix deployment contract and boot metadata.

## Start here

- [Requirements and safety checks](docs/requirements.md)
- [Quickstart](docs/quickstart.md), using the [example flake](examples/flake.nix)
- [CLI and deployment reference](docs/reference.md)

The validated layout uses **UEFI, Limine, GPT, an EFI System Partition, and an
ext4 root filesystem**: automated disk-boot coverage on x86_64 Linux and a manual
deployment on a Hetzner CAX11 (aarch64). Other bootloaders, disk layouts, and
hardware remain unverified. `--vm-test` and NixOS hardware-configuration generation
are explicitly unsupported; supply a Finix configuration instead.

From a checkout, after completing the quickstart preflight:

```sh
nix run path:.#finix-anywhere -- --flake 'path:.?dir=examples#target' --target-host root@TARGET_IP
```

Do not run this command with the example's unreviewed disk or credentials.

## Development check

The integrated installation check is:

```sh
nix build .#checks.x86_64-linux.installation -L
```

For a checkout with untracked project files, use
`nix build path:.#checks.x86_64-linux.installation -L` instead.

The check requires an x86_64 Linux builder with KVM. It exercises the real CLI's
kexec transition from a systemd source VM into the native Finix RAM installer,
followed by installation and two UEFI cold boots from disk without an injected
kernel/initrd or shared Nix store. Assertions cover Finit as PID 1, authenticated
SSH through the example's `/etc/ssh/authorized_keys` path, persistent profiles and
files, host-key preservation, file ownership/modes, and password-file credentials.
Authorized keys are materialized as regular files so OpenSSH's `StrictModes`
does not traverse `/nix/store`.

`checks.x86_64-linux.cli` exercises rejection of invalid deployments before SSH.
The systemd source VM uses NixOS for the test harness; the RAM installer and
installation commands are native Finix. This is not automated ARM or
physical-hardware coverage.
The check also executes an isolated Nix sandbox build inside the RAM installer,
covering the mounted-root requirement for remote builds.

The native path also passed manually on a Hetzner CAX11 (aarch64, 4 GiB), starting
from stock Ubuntu 24.04.4 with no NixOS installer: source-host Nix bootstrap,
remote image/build execution, Finix RAM boot, destructive installation to
`/dev/sda`, and UEFI disk boot. Public-key SSH with the original ed25519 host
identity, Finit as PID 1, the Nix daemon, and persistent data were verified again
after a further reboot. Other server types and network layouts remain unverified.

## Provenance and license

Forked from [nix-community/nixos-anywhere at
`da83557d8b0bce57a52371b888ffd6d58724e55c`](https://github.com/nix-community/nixos-anywhere/tree/da83557d8b0bce57a52371b888ffd6d58724e55c).
The upstream work is copyright (c) 2022 Numtide and remains under the
[MIT license](LICENSE). This fork does not imply endorsement or support by Numtide
or the upstream maintainers.

The deployment baseline pins Finix to
`bb5965afe646b8c1055be3646b6df39e754d03a3` and nixpkgs to
`8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe`, matching Finix's `lon.lock`.
