# Requirements and safety

## Scope

The validated layout uses UEFI firmware, a Limine bootloader, a GPT disk, a FAT
EFI System Partition, and an ext4 root filesystem. Automated coverage is on
x86_64; a manual deployment and reboot check also passed on a Hetzner CAX11
(aarch64). Other hardware is unverified. The example is deliberately narrower
than upstream nixos-anywhere or disko.
Packaging the CLI for another host platform does not establish that platform as a
supported installed system.

The installed system must be built with Finix, not `nixpkgs.lib.nixosSystem`.
Use Finix's `finix.lib.finixSystem` and export it under
`nixosConfigurations.<name>`. Import `finix-anywhere.nixosModules.default`; this
provides the disko module and requires a real bootloader, kernel, initrd, and
bootspec metadata. It does not choose a disk, bootloader, network, or credentials
for you. See `examples/flake.nix` in the repository.

## Deployment host

- Nix with flakes and `nix-command` support, access to this checkout and your target
  configuration, and permission to build or copy the relevant closures.
- SSH connectivity to the target and enough local storage for builds. An x86_64
  Linux builder is the straightforward choice for the initial target; use
  `--build-on remote` when the local host cannot build the target system.
- Access to the configured binary caches or the resources to build from source.
  Remote building also needs sufficient RAM, store space, and network access in
  the rescue environment.

## Target and rescue environment

- A disposable target, or a verified backup of **every disk selected by disko**.
  The default `disko` phase destroys existing partition tables and filesystems.
- Root SSH access, or an account able to elevate with the supported `sudo`/`doas`
  flow. Confirm access before deployment; the process reconnects as root in the
  rescue environment.
- A systemd Linux source host such as Ubuntu 24.04, with `iproute2`, a working
  kexec syscall, and root access; or an already-running native Finix RAM installer.
  The bundled images support x86_64 and aarch64. Secure Boot/kernel lockdown can
  prohibit kexec. An ordinary NixOS installer is not the required RAM environment.
- Remote building bootstraps Nix on the source host if absent; it requires
  `curl` or `wget`, `tar`, `sha256sum`, writable `/nix`, and Internet access.
- Sufficient RAM for the unpacked installer closure, builds, and temporary files.
  Boot temporarily copies the closure into a mounted tmpfs root so Nix sandbox
  builds can use `pivot_root`, then frees the original image. The exercised VM
  configuration uses 4 GiB; the inherited 1 GiB preflight floor is not a sizing
  guarantee. Do not rely on disk swap surviving repartitioning.
- Physical wired Ethernet, standard routing tables, and an ed25519 host key at
  `/etc/ssh/ssh_host_ed25519_key`. The launcher restores addresses, main-table
  routes, MTU, and DNS, matching interfaces by MAC. It rejects addressed bridges,
  bonds, VLANs, tunnels, Wi-Fi, and policy routing instead of silently dropping
  their configuration.
- Authorized keys in `/root/.ssh/authorized_keys` (or the sudo user's standard
  key file). Custom `AuthorizedKeysCommand` setups are not migrated. SSH keys
  and network state are appended privately on the source host, not built into
  the Nix-store image.
- UEFI firmware for the first supported layout, and console/out-of-band recovery
  access in case networking or boot configuration is incorrect.

## Preflight: real access, not placeholders

Before starting:

1. Verify the machine's identity and IP through a trusted independent channel.
   **The installer disables strict SSH host-key verification and does not maintain
   known hosts.** This weakens server authentication even if your SSH client is
   normally configured more strictly. Do not use the installer across an
   untrusted network on the assumption that host keys will protect you.
2. Connect with ordinary SSH and inspect disks, firmware mode, free RAM, and
   networking. Use stable `/dev/disk/by-id/…` disk identifiers where possible;
   `/dev/vda` is only an example VM disk name.
3. Supply a real public key for the installed system. The rescue login key is not
   automatically a permanent login credential. Keep private keys outside the Nix
   store and Git.
4. Configure the installed Finix network, including the correct interface, DHCP
   or static address, routes, and DNS. Rescue connectivity does not prove that
   networking will work after reboot.
5. Build and inspect the target's toplevel and disko script. Confirm the disk path,
   EFI mount point, root filesystem, and Limine configuration before formatting.
6. Arrange a way to reach the console and restore backups. A successful installer
   exit or reboot request does not prove boot or SSH readiness.

Do not install onto a production server that has not been evacuated and backed
up. Phased operation and `--disko-mode mount` are not substitutes for reviewing the
configuration.
