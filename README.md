# finix-anywhere

Install [Finix](https://github.com/finix-community/finix) over SSH using a NixOS
rescue environment and disko. This is a focused fork of
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
2. Reuse a suitable NixOS installer, or boot a NixOS rescue image with `kexec`.
3. Run the target's disko script to prepare its disks.
4. Copy the **Finix** system closure and install it with the rescue environment's
   `nixos-install --system`.
5. Boot the installed Finix system.

NixOS is the temporary installation environment, not the installed operating
system. Finix uses the `nixosConfigurations.<name>` flake output convention. Each
deployment must import this fork's `nixosModules.default`, which combines disko
with the Finix deployment contract and boot metadata.

## Start here

- [Requirements and safety checks](docs/requirements.md)
- [Quickstart](docs/quickstart.md), using the [example flake](examples/flake.nix)
- [CLI and deployment reference](docs/reference.md)

The initial supported target is **x86_64 Linux, UEFI, Limine, GPT, an EFI System
Partition, and an ext4 root filesystem**. Other bootloaders, disk layouts,
architectures, and upstream disko integrations are not established by this
example. `--vm-test` and NixOS hardware-configuration generation are explicitly
unsupported; supply a Finix configuration instead.

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

The check requires an x86_64 Linux builder with KVM. It has passed for the pinned
configuration: the real CLI installs over SSH, then the installed disk cold-boots
twice under UEFI without an injected kernel/initrd or shared Nix store. It checks
Finit as PID 1, authenticated SSH, persistent system profiles and files, host-key
preservation, file ownership/modes, and password-file credentials.

`checks.x86_64-linux.cli` exercises rejection of invalid deployments before SSH.
The installation scenario starts in a NixOS installer; it does not establish
kexec transition, remote-build, other-architecture, or physical-hardware support.

## Provenance and license

Forked from [nix-community/nixos-anywhere at
`da83557d8b0bce57a52371b888ffd6d58724e55c`](https://github.com/nix-community/nixos-anywhere/tree/da83557d8b0bce57a52371b888ffd6d58724e55c).
The upstream work is copyright (c) 2022 Numtide and remains under the
[MIT license](LICENSE). This fork does not imply endorsement or support by Numtide
or the upstream maintainers.

The deployment baseline pins Finix to
`bb5965afe646b8c1055be3646b6df39e754d03a3` and nixpkgs to
`8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe`, matching Finix's `lon.lock`.
