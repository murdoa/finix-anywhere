{ pkgs, finix }:
let
  inherit (pkgs) lib;
  rescue = import ./system.nix { inherit pkgs finix; };
  system = rescue.config.system.topLevel;
  kernel = rescue.config.boot.kernelPackages.kernel;
  kernelFile = kernel.target or pkgs.stdenv.hostPlatform.linux-kernel.target;
  bootstrap = pkgs.replaceVars ./init.sh {
    shell = "${pkgs.bash}/bin/bash";
    bootstrapPath = lib.makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.nix ];
    nixbldGid = toString rescue.config.users.groups.nixbld.gid;
    inherit system;
  };
  closure = pkgs.closureInfo { rootPaths = [ system bootstrap ]; };

  # Copy the complete runtime closure, not only ELF references reachable from
  # /init. Activation scripts and Finit configuration have runtime store edges.
  # At boot /init copies it into a mounted tmpfs root for Nix sandbox support;
  # switch_root then frees the original unpacked image.
  initrd = pkgs.runCommand "finix-installer-initrd" {
    __structuredAttrs = true;
    nativeBuildInputs = [ pkgs.cpio pkgs.gzip ];
    unsafeDiscardReferences.out = true;
  } ''
    mkdir -p root/{nix/store,dev,proc,sys,run,tmp,var/empty}
    while IFS= read -r path; do
      cp -a --reflink=auto "$path" root/nix/store/
    done < ${closure}/store-paths
    install -m 0555 ${bootstrap} root/init
    install -m 0444 ${closure}/registration root/registration
    mkdir "$out"
    (cd root && find . -exec touch -h -d '@1' '{}' +)
    (cd root && find . -print0 | sort -z | cpio --quiet -o -H newc -R +0:+0 --reproducible --null | gzip -n -1 > "$out/initrd")
  '';

  # Musl/static variants are mandatory: the launch host may be stock Ubuntu
  # with no /nix at all. Copying a normal Nix kexec binary would not work there.
  staticKexec = pkgs.pkgsStatic.kexec-tools;
  staticBusybox = pkgs.pkgsStatic.busybox.override {
    enableStatic = true;
    extraConfig = ''
      CONFIG_CPIO y
      CONFIG_FEATURE_CPIO_O y
      CONFIG_FEATURE_CPIO_P y
      CONFIG_SETSID y
    '';
  };
in
assert lib.assertMsg (lib.elem pkgs.stdenv.hostPlatform.system [ "aarch64-linux" "x86_64-linux" ])
  "finix-installer supports aarch64-linux and x86_64-linux";
pkgs.runCommand "finix-installer" {
  __structuredAttrs = true;
  nativeBuildInputs = [ pkgs.gnutar pkgs.gzip pkgs.binutils ];
  unsafeDiscardReferences.out = true;
  passthru = {
    inherit initrd;
    rescueSystem = system;
    closureInfo = closure;
  };
} ''
  mkdir -p kexec "$out"
  install -m 0555 ${./run.sh} kexec/run
  install -m 0555 ${./launch.sh} kexec/launch
  install -m 0555 ${lib.getExe staticKexec} kexec/kexec
  install -m 0555 ${lib.getExe staticBusybox} kexec/busybox
  for executable in kexec/kexec kexec/busybox; do
    if readelf -l "$executable" | grep -q INTERP || readelf -d "$executable" | grep -q '(NEEDED)'; then
      echo "Installer loader is not standalone: $executable" >&2
      exit 1
    fi
  done
  install -m 0444 ${kernel}/${kernelFile} kexec/kernel
  install -m 0444 ${initrd}/initrd kexec/initrd
  printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep " " ([ "rdinit=/init" ] ++ rescue.config.boot.kernelParams))} > kexec/kernel-params
  printf '%s\n' ${if pkgs.stdenv.hostPlatform.isAarch64 then "aarch64" else "x86_64"} > kexec/architecture
  cp ${closure}/total-nar-size kexec/closure-size
  tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner -cf - kexec | gzip -n -1 > "$out/finix-installer.tar.gz"
''
