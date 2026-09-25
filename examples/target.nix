{
  finix,
  deploymentModule,
  pkgs,
  authorizedKeysFile,
  disk ? "/dev/vda",
  extraModules ? [ ],
}:
finix.lib.finixSystem {
  inherit (pkgs) lib;
  modules = [
    deploymentModule
    finix.nixosModules.getty
    finix.nixosModules.sysklogd
    finix.nixosModules.dhcpcd
    finix.nixosModules.openssh
    finix.nixosModules.nix-daemon
    finix.nixosModules.ifupdown-ng
    finix.nixosModules.limine
    ({ lib, ... }: {
      nixpkgs.pkgs = pkgs;
      networking.hostName = "finix-target";

      # The default Finix module imports mdevd; these other services are opt-in.
      services.getty.enable = true;
      services.mdevd.enable = true;
      services.sysklogd.enable = true;
      services.dhcpcd.enable = true;
      services.nix-daemon.enable = true;
      programs.ifupdown-ng = {
        enable = true;
        auto = [ "lo" ];
        iface.lo.address = "127.0.0.1/8";
      };
      services.openssh = {
        enable = true;
        settings = {
          PermitRootLogin = "prohibit-password";
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          AuthorizedKeysFile = "/etc/ssh/authorized_keys/%u";
        };
      };
      # StrictModes follows symlinks and rejects the group-writable Nix store.
      # Keep the public source in the store, but materialize a root-owned file.
      environment.etc."ssh/authorized_keys/root" = {
        source = authorizedKeysFile;
        mode = "0600";
      };

      programs.limine = {
        enable = true;
        efiSupport = true;
        biosSupport = false;
        efiInstallAsRemovable = true;
        settings.timeout = 1;
        settings.wallpaper = lib.mkForce [ ];
      };
      boot.loader.efi = {
        canTouchEfiVariables = false;
        efiSysMountPoint = "/boot";
      };
      # Adjust this list for real hardware; this example covers virtio and common disks.
      boot.initrd.availableKernelModules = [
        "virtio_pci" "virtio_blk" "virtio_scsi" "ahci" "nvme" "sd_mod"
      ];
      boot.kernelModules = [ "virtio_net" ];

      # Only this plain GPT ESP + ext4 layout is covered by the installation check.
      disko.devices.disk.system = {
        type = "disk";
        device = disk;
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    })
  ] ++ extraModules;
}
