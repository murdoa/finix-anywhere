{ pkgs, inputs, finix-anywhere, deploymentModule }:
{
  installation = import ./installation.nix {
    inherit pkgs finix-anywhere deploymentModule;
    inherit (inputs) finix;
  };
}
