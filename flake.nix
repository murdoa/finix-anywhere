{
  description = "Install Finix over SSH using a native Finix RAM installer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe";
    finix.url = "github:finix-community/finix/bb5965afe646b8c1055be3646b6df39e754d03a3";
    disko = {
      url = "github:nix-community/disko/725ea35e410ad83be4931d1bff7e090eacaf3563";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      eachSystem = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      nixosModules.default = {
        imports = [ inputs.disko.nixosModules.disko ./modules/deployment.nix ];
      };

      packages = eachSystem (pkgs: {
        finix-anywhere = pkgs.callPackage ./src { installerFlake = self.outPath; };
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.finix-anywhere;
        docs = pkgs.callPackage ./docs { };
      } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        installer = import ./installer { inherit pkgs; inherit (inputs) finix; };
      });

      devShells = eachSystem (pkgs: {
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.finix-anywhere.devShell;
      });

      formatter = eachSystem (pkgs: pkgs.nixfmt-tree);

      checks = eachSystem (pkgs: {
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.finix-anywhere;
        cli = pkgs.runCommand "finix-anywhere-cli" {
          nativeBuildInputs = with pkgs; [ bash coreutils jq gnugrep nix openssh ];
        } ''
          bash ${./tests/cli.sh} ${self.packages.${pkgs.stdenv.hostPlatform.system}.finix-anywhere}/bin/finix-anywhere
          touch "$out"
        '';
      } // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") (
        import ./tests {
          inherit pkgs inputs;
          finix-anywhere = self.packages.${pkgs.stdenv.hostPlatform.system}.finix-anywhere;
          deploymentModule = self.nixosModules.default;
          ramInstaller = self.packages.${pkgs.stdenv.hostPlatform.system}.installer;
        }
      ));
    };
}
