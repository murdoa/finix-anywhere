{ pkgs, finix }:
let
  restoreNetwork = pkgs.writeShellScript "finix-installer-network" ''
    export PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.iproute2 pkgs.jq ]}
    ${builtins.readFile ./restore-network.sh}
  '';
in
finix.lib.finixSystem {
  inherit (pkgs) lib;
  modules = [
    finix.nixosModules.getty
    finix.nixosModules.sysklogd
    finix.nixosModules.dhcpcd
    finix.nixosModules.openssh
    finix.nixosModules.nix-daemon
    finix.nixosModules.ifupdown-ng
    ({ lib, ... }: {
      nixpkgs.pkgs = pkgs;
      networking.hostName = "finix-installer";

      # The outer image embeds this system's closure. Including an initrd here
      # would both duplicate the image and introduce a dependency cycle.
      boot.initrd.enable = false;
      # /init switches into a writable tmpfs root, independent of the source disk.
      fileSystems = { };
      finit.tasks.remount-nix-store.enable = lib.mkForce false;
      boot.kernelParams = [
        "rootfstype=tmpfs"
        "console=tty0"
        (if pkgs.stdenv.hostPlatform.isAarch64 then "console=ttyAMA0,115200" else "console=ttyS0,115200")
      ];
      boot.kernelModules = lib.mkForce (
        [ "loop" "virtio_pci" "virtio_net" "virtio_blk" "virtio_scsi" "nvme" "sd_mod" "dm_mod" ]
        ++ lib.optionals pkgs.stdenv.hostPlatform.isAarch64 [ "virtio_mmio" ]
        ++ lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [ "ahci" ]
      );
      # An installer must not depend on a persistent random MAC-specific secret
      # just to acquire an IPv6 link-local address after kexec.
      boot.kernel.sysctl."net.ipv6.conf.all.addr_gen_mode" = lib.mkForce 0;
      boot.kernel.sysctl."net.ipv6.conf.default.addr_gen_mode" = 0;

      services.mdevd.enable = true;
      services.getty.enable = true;
      services.sysklogd.enable = true;
      programs.ifupdown-ng = {
        enable = true;
        auto = [ "lo" ];
        iface.lo.address = "127.0.0.1/8";
      };
      programs.resolvconf.enable = true;
      # Preserve the captured resolver until DHCP actually supplies a new one.
      finit.tasks.resolvconf.enable = lib.mkForce false;
      services.dhcpcd.enable = true;
      services.dhcpcd.settings.noalias = false;
      finit.tasks.installer-network = {
        description = "restore installer network by hardware address";
        command = restoreNetwork;
        runlevel = "S";
        conditions = [ "run/coldplug/success" ];
        log = true;
      };
      finit.services.dhcpcd.conditions = lib.mkAfter [ "task/installer-network/success" ];

      services.openssh = {
        enable = true;
        settings = {
          PermitRootLogin = "prohibit-password";
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          AuthorizedKeysFile = "/root/.ssh/authorized_keys";
        };
      };
      # SSH secrets are populated by /init from the target-only appended cpio,
      # not environment.etc or any other build-store source.
      environment.etc."finix-installer".text = "1\n";
      environment.etc."ssl/certs/ca-certificates.crt".source = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      services.nix-daemon = {
        enable = true;
        settings = {
          experimental-features = [ "nix-command" "flakes" ];
          build-users-group = "nixbld";
          ssl-cert-file = "/etc/ssl/certs/ca-certificates.crt";
        };
      };
      environment.systemPackages = with pkgs; [
        bashInteractive coreutils util-linux jq nix gnutar gzip cpio curl
        openssh iproute2 gnugrep findutils kmod cacert
      ];
      finit.tmpfiles.rules = [ "d /mnt 0755" ];
    })
  ];
}
