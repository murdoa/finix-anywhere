{ pkgs, inputs, finix-anywhere, deploymentModule, ramInstaller }:
{
  installation = import ./installation.nix {
    inherit pkgs finix-anywhere deploymentModule ramInstaller;
    inherit (inputs) finix;
  };
}
