{
  description = "Finix Anywhere: x86_64 UEFI target with Limine and DHCP";

  inputs = {
    finix-anywhere.url = "path:..";
    nixpkgs.follows = "finix-anywhere/nixpkgs";
    finix.follows = "finix-anywhere/finix";
  };

  outputs = { finix-anywhere, nixpkgs, finix, ... }: {
    nixosConfigurations.target = import ./target.nix {
      inherit finix;
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      deploymentModule = finix-anywhere.nixosModules.default;
      # Create this file with your real SSH public key before evaluating the example.
      authorizedKeysFile = ./authorized_keys;
      # DESTRUCTIVE: replace this with the disk you intend to erase.
      disk = "/dev/vda";
    };
  };
}
