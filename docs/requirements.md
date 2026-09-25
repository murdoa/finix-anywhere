# Requirements and safety

## Scope

The initial deployment target is x86_64 Linux with UEFI firmware, a Limine
bootloader, a GPT disk, a FAT EFI System Partition, and an ext4 root filesystem.
The example is deliberately narrower than upstream nixos-anywhere or disko.
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
- A suitable NixOS installer booted already, or a Linux system able to run the
  supplied `kexec` rescue image. The default rescue-image path is for x86_64.
  If `kexec` is unavailable or blocked, boot a NixOS installer through your
  console/provider instead.
- At least 1 GiB RAM excluding swap for the inherited `kexec` path; actual builds
  and closures may need substantially more. Do not rely on disk swap surviving
  repartitioning.
- Wired networking that survives the rescue transition. The tool does not migrate
  arbitrary Wi-Fi, VPN, VLAN, or static network setup into the default rescue
  image. Arrange an appropriate custom rescue image or booted installer when
  needed.
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
