{ config, pkgs, ... }:
{
  # nixos-enter executes the target's sw/bin/bash during bootloader installation.
  environment.systemPackages = [ pkgs.bash ];

  assertions = [
    {
      assertion = config.providers.bootloader.backend != "none";
      message = "finix-anywhere requires a bootloader; import and enable programs.limine or configure boot.loader.script.";
    }
    {
      assertion = config.boot.kernel.enable && config.boot.initrd.enable;
      message = "finix-anywhere requires a kernel and initrd for the installed machine.";
    }
    {
      assertion = config.boot.bootspec.enable && config.boot.bootspec.filename == "boot.json";
      message = "finix-anywhere requires the deployment bootspec at boot.json.";
    }
  ];

  # Carry the installation contract with prebuilt closures as well as flakes.
  boot.bootspec.extensions."org.finix-anywhere.v1" = {
    bootloader = config.providers.bootloader.backend;
    hostKeys = config.services.openssh.settings.HostKey or [ ];
  };
}
