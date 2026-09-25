# Deployment and CLI reference

Run `nix run path:.#finix-anywhere -- --help` from the checkout for the executable's
option summary. Examples below use that invocation; an installed
`finix-anywhere` command accepts the same arguments.

## Configuration contract

`--flake ./path#target` selects
`nixosConfigurations.target.config`. This namespace is Finix's convention, not
an instruction to build NixOS. The configuration must import
`finix-anywhere.nixosModules.default` and expose:

- `system.build.toplevel`: the bootable Finix system closure;
- `system.build.diskoScript`: the disk preparation script for the default mode;
- a real bootloader backend, enabled kernel/initrd and bootspec, and deployment
  metadata supplied by the module.

The module publishes
`boot.bootspec.extensions."org.finix-anywhere.v1"`, including the selected
bootloader and SSH `HostKey` paths. The built `boot.json` also records the target
platform through `org.nixos.bootspec.v1.system`. Do not remove or forge these
markers to bypass a deployment rejection: they are part of the installer
contract, not a proof of hardware compatibility.

The installer uses the NixOS rescue environment's `nixos-install --system` with
the **Finix** closure. Rescue OS detection, kexec image selection, and installer
commands intentionally still refer to NixOS.

## Target, authentication, and rescue

| Option | Purpose |
| --- | --- |
| `-f, --flake URI#NAME` | Select the Finix configuration. |
| `--target-host USER@HOST` | SSH target; a positional SSH host is also accepted. |
| `-i FILE` | SSH private key for connecting to the existing target. |
| `-p, --ssh-port PORT` | Initial SSH port. |
| `--ssh-option OPTION` | Add an SSH option without `-o`; repeat as needed. |
| `--env-password` | Use `SSHPASS` for initial SSH key setup. Treat it as a secret. |
| `--kexec PATH_OR_URL` | Supply a different NixOS rescue tarball. |
| `--force-kexec` | Run kexec even when a suitable installer is detected. |
| `--kexec-extra-flags FLAGS` | Additional flags passed to kexec. |
| `--post-kexec-ssh-port PORT` | SSH port after the rescue transition; default 22. |

**Security warning:** inherited SSH arguments set `StrictHostKeyChecking=no` and
`UserKnownHostsFile=/dev/null`. They bypass normal host identity protection. Do
not assume adding a later `--ssh-option` restores it; OpenSSH commonly uses the
first value for an option. Use independently verified targets and a trusted
network. This tool is not a hardened SSH transport.

A custom rescue image is still an installation environment, not your Finix target
configuration. It must provide the network and installer tools needed by the
retained NixOS rescue flow.

## Building, prebuilt paths, and caches

`--build-on auto|local|remote` controls where builds happen. The default `auto`
selects a build location based on available platform support. Choose `local` to
use the local Nix build machinery (including its configured builders), or `remote`
to build through the target's rescue environment. Remote builds still require a
locally evaluable configuration and enough resources on the target.

To prepare both paths explicitly for the initial layout:

```sh
disko=$(nix build --no-link --print-out-paths 'path:.?dir=examples#nixosConfigurations.target.config.system.build.diskoScript')
system=$(nix build --no-link --print-out-paths 'path:.?dir=examples#nixosConfigurations.target.config.system.build.toplevel')
nix run path:.#finix-anywhere -- --store-paths "$disko" "$system" --target-host root@TARGET_IP
```

`-s, --store-paths DISKO_SCRIPT FINIX_SYSTEM` avoids selecting a flake at invocation
time. The system path must still be a Finix deployment closure carrying the
required `boot.json` metadata and Finix version marker; arbitrary NixOS store
paths are not interchangeable. Build both paths from the same reviewed target
configuration. Prebuilt paths do not discover cache settings from a target flake.

The disk artifact may be an executable script or a package containing `bin/disko`.
Flake-selected format and mount packages use `bin/disko-format` and
`bin/disko-mount`, respectively.

| Option | Purpose |
| --- | --- |
| `--from STORE_URI` | Source Nix store for closure copying. |
| `--no-substitute-on-destination` | Disable substitution at the destination; also disables importing the target configuration's substituters. |
| `--no-use-machine-substituters` | Do not import the target configuration's substituters and trusted public keys into the rescue environment. |
| `--ssh-store-setting KEY VALUE` | Add an SSH-store URI setting; URI-encode the value. |
| `--option KEY VALUE` | Pass a Nix option to Nix commands. Repeat as needed. |
| `-L, --print-build-logs` | Show full build logs. |
| `--show-trace` | Show Nix evaluation traces. |
| `--debug` | Verbose shell diagnostics; output may expose secrets. |

When a flake is supplied, the normal flow imports
`services.nix-daemon.settings.substituters` and
`services.nix-daemon.settings.trusted-public-keys` into the rescue environment.
Absent settings default to empty lists. Trust only caches and keys you have
reviewed. Cache availability does not replace a matching build platform.

## Phases and disk modes

The default is `--phases kexec,disko,install,reboot`:

1. `kexec`: inspect the target and, if needed, transition into NixOS rescue.
2. `disko`: prepare and mount disks at `/mnt`. The default mode is destructive.
3. `install`: copy files and the Finix closure, activate the installation, and
   install its bootloader.
4. `reboot`: unmount filesystems and request a reboot.

The comma-separated list selects phases; execution follows this fixed order,
not the order in which names are listed. Skipping prerequisites does not recreate
their state. When omitting `kexec`, prepare the rescue environment and root SSH
access yourself. When omitting `disko`, ensure the intended filesystems are
already mounted at `/mnt`.

To install but leave the machine in rescue for inspection:

```sh
nix run path:.#finix-anywhere -- --flake 'path:.?dir=examples#target' \
  --target-host root@TARGET_IP --phases kexec,disko,install
```

To resume installation on already prepared disks in rescue:

```sh
nix run path:.#finix-anywhere -- --flake 'path:.?dir=examples#target' \
  --target-host root@TARGET_IP --phases disko,install,reboot --disko-mode mount
```

`--disko-mode disko|mount|format` selects the corresponding disko script. `disko`
destroys the existing layout, creates filesystems, and mounts them. `mount` is for
an existing matching layout. `format` creates/formats the configured layout and
can destroy data; it is not a dry run. Inspect the selected script before using
nondefault modes. With `--store-paths`, supply the script for the mode you intend.

`--no-disko-deps` copies the script without its partitioning-tool dependencies.
Use it only if your rescue environment already supplies the correct tools. It is
not a general low-memory guarantee.

## Extra files and secrets

`--extra-files DIRECTORY` copies the directory's contents into the installed root
under `/mnt`, overwriting matching files. Paths mirror the final filesystem:
`DIRECTORY/var/lib/my-service/secret` becomes `/var/lib/my-service/secret`. Files
are copied as root. Use `--chown PATH UID:GID` for recursive ownership changes;
repeat it for separate paths, and use IDs belonging to the installed Finix system.

Keep secret source directories outside Git and the Nix store, restrict their
permissions, and avoid `--debug` while handling secrets. Do not commit a private
SSH key or password just to make a flake evaluate.

`--disk-encryption-keys REMOTE_PATH LOCAL_PATH` copies a local file or pipe into
the rescue environment after kexec and before disk preparation; it can be
repeated. This retains an upstream facility, not a claim that an encrypted Finix
layout is covered by the initial ESP/ext4 example.

`--copy-host-keys` preserves an existing ed25519 host identity from the original
target, captured before kexec. The source preference is
`/var/lib/sshd/ssh_host_ed25519_key`, then
`/etc/ssh/ssh_host_ed25519_key`. The destination must match the installed Finix
configuration's declared `HostKey` paths; the default Finix destination is
`/var/lib/sshd/ssh_host_ed25519_key`. Missing keys or unsupported mappings are
errors, rather than silently copying every `/etc/ssh/ssh_host_*` file. This option
preserves the server's identity, **not** user authorized keys, and does not restore
host verification during deployment.

This option requires the `install` phase and an unencrypted ed25519 private key.
Configured destination paths must be safe absolute paths ending in
`ssh_host_ed25519_key`; other host-key types are not supported. Preserved keys
are installed after `--extra-files` and take precedence at those paths, with
root ownership and modes 0600 for private keys and 0644 for public keys.

## Unsupported upstream workflows

- `--vm-test` is rejected. For this fork's integrated installation scenario, use
  `nix build .#checks.x86_64-linux.installation -L`. This is a repository check,
  not an arbitrary-target VM validator.
- `--generate-hardware-config` is rejected. Supply an explicit Finix hardware and
  boot configuration; generated NixOS hardware/facter modules are not promised to
  be compatible.
- Copied upstream Terraform, no-flake, and generalized hardware recipes are not
  part of this fork's documented interface. Do not assume an upstream tutorial
  applies unchanged.

Installation completion only means the requested installation/reboot actions
completed. Confirm Finix boot, network access, SSH authentication, mounted
filesystems, and application health separately through your console and SSH.
