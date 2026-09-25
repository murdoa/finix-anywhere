{ pkgs, finix, finix-anywhere, deploymentModule }:
let
  target = import ../examples/target.nix {
    inherit pkgs finix deploymentModule;
    authorizedKeysFile = ./modules/ssh-keys/ssh.pub;
    disk = "/dev/vdb";
    extraModules = [
      ({ lib, ... }: {
        boot.kernelParams = [ "console=ttyS0,115200n8" ];
        services.getty.ttys = [ "ttyS0" ];
        services.openssh.settings = {
          AuthorizedKeysFile = lib.mkForce ".ssh/authorized_keys";
          PasswordAuthentication = lib.mkForce true;
        };
        users.users.operator = {
          isNormalUser = true;
          uid = 1000;
          passwordFile = "/var/lib/credentials/operator-password";
        };
      })
    ];
  };
  system = target.config.system.build.toplevel;
  disko = target.config.system.build.diskoScript;
  nixos-lib = import (pkgs.path + "/nixos/lib") { };
in
(nixos-lib.runTest {
  name = "finix-anywhere-installation";
  hostPkgs = pkgs;
  globalTimeout = 1800;

  defaults = { lib, ... }: {
    documentation.enable = false;
    virtualisation = {
      memorySize = 2048;
      cores = 2;
      diskSize = 1024;
    };
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      substituters = lib.mkForce [ ];
    };
  };

  nodes = {
    deployer = { ... }: {
      environment.systemPackages = [ finix-anywhere pkgs.openssl ];
      environment.etc = {
        "finix-anywhere/system".source = system;
        "finix-anywhere/disko".source = disko;
      };
      system.activationScripts.install-key = ''
        install -D -m600 ${./modules/ssh-keys/ssh} /root/.ssh/install_key
      '';
    };

    installer = { ... }: {
      system.nixos.variant_id = "installer";
      services.openssh = {
        enable = true;
        settings.PasswordAuthentication = false;
        hostKeys = [{ path = "/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }];
      };
      users.users.root.openssh.authorizedKeys.keyFiles = [ ./modules/ssh-keys/ssh.pub ];
      # /dev/vda belongs to the rescue VM; only this initially blank disk is erased.
      virtualisation.emptyDiskImages = [ 6144 ];
    };
  };

  testScript = ''
    import shutil
    import socket
    import subprocess
    import time

    start_all()
    installer.wait_for_unit("sshd.service")
    installer.succeed("test -b /dev/vdb; test -z \"$(lsblk -n -o FSTYPE /dev/vdb)\"")
    host_key = installer.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub").strip()
    deployer.wait_until_succeeds("ssh -i /root/.ssh/install_key -o StrictHostKeyChecking=no root@installer true")

    with subtest("install the real Finix closure through the public CLI"):
        deployer.succeed("""
          set -eu
          mkdir -p /tmp/extra/root/.ssh /tmp/extra/home/operator/.ssh /tmp/extra/var/lib/credentials
          chmod 700 /tmp/extra/root/.ssh /tmp/extra/home/operator/.ssh /tmp/extra/var/lib/credentials
          cp ${./modules/ssh-keys/ssh.pub} /tmp/extra/root/.ssh/authorized_keys
          cp ${./modules/ssh-keys/ssh.pub} /tmp/extra/home/operator/.ssh/authorized_keys
          printf '%s\\n' persistent-extra-file > /tmp/extra/home/operator/.ssh/secret
          printf '%s' finix-install-password | openssl passwd -6 -stdin > /tmp/extra/var/lib/credentials/operator-password
          chmod 600 /tmp/extra/root/.ssh/authorized_keys /tmp/extra/home/operator/.ssh/* /tmp/extra/var/lib/credentials/operator-password
          finix-anywhere \\
            --debug \\
            --build-on local \\
            --phases kexec,disko,install \\
            --store-paths /etc/finix-anywhere/disko /etc/finix-anywhere/system \\
            --extra-files /tmp/extra \\
            --chown /home/operator 1000:100 \\
            --copy-host-keys \\
            -i /root/.ssh/install_key \\
            root@installer </dev/null >&2
        """, timeout=300)
        installer.succeed("test -f /mnt/boot/EFI/BOOT/BOOTX64.EFI")
        installer.succeed("test $(readlink -f /mnt/nix/var/nix/profiles/system) = ${system}")
        installer.succeed("sync")
        installer.shutdown()
        deployer.shutdown()

    disk = installer.state_dir / "empty0.qcow2"
    assert disk.is_file(), f"missing installed disk: {disk}"
    work = installer.state_dir / "finix-boot"
    work.mkdir()
    key = work / "ssh-key"
    shutil.copyfile("${./modules/ssh-keys/ssh}", key)
    key.chmod(0o600)
    known_hosts = work / "known_hosts"
    known_hosts.write_text("finix-installed " + host_key + "\n")
    firmware_vars = work / "OVMF_VARS.fd"
    shutil.copyfile("${pkgs.OVMF.fd}/FV/OVMF_VARS.fd", firmware_vars)
    firmware_vars.chmod(0o600)
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        ssh_port = reservation.getsockname()[1]

    ssh_options = [
        "-p", str(ssh_port),
        "-o", "ConnectTimeout=3",
        "-o", "UserKnownHostsFile=" + str(known_hosts),
        "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "HostKeyAlias=finix-installed",
        "-o", "StrictHostKeyChecking=yes",
    ]

    def ssh(command, user="root", password=False, check=True):
        argv = ["${pkgs.openssh}/bin/ssh", *ssh_options]
        if password:
            argv = ["${pkgs.sshpass}/bin/sshpass", "-p", "finix-install-password", *argv]
            argv += ["-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no"]
        else:
            argv += ["-i", str(key), "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes"]
        result = subprocess.run(
            [*argv, user + "@127.0.0.1", command],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30,
        )
        if check:
            assert result.returncode == 0, result.stdout + result.stderr
        return result

    def wait_for_ssh(process):
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            assert process.poll() is None, "installed guest exited before SSH became ready"
            result = ssh("true", check=False)
            if result.returncode == 0:
                return
            time.sleep(1)
        raise AssertionError("Finix SSH did not become ready: " + result.stderr)

    # This is deliberately not a Finix/NixOS test VM: only firmware, the installed
    # disk, and a network card. No -kernel/-initrd, 9p, virtiofs, or store mounts.
    qemu = [
        "${pkgs.qemu_test}/bin/qemu-kvm",
        "-machine", "q35,accel=kvm", "-cpu", "host", "-m", "2048", "-smp", "2",
        "-display", "none", "-monitor", "none", "-no-reboot",
        "-drive", "if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd",
        "-drive", "if=pflash,format=raw,file=" + str(firmware_vars),
        "-drive", "if=none,id=installed,format=qcow2,file=" + str(disk),
        "-device", "virtio-blk-pci,drive=installed,bootindex=1",
        "-netdev", f"user,id=net,hostfwd=tcp:127.0.0.1:{ssh_port}-:22",
        "-device", "virtio-net-pci,netdev=net",
    ]

    def check_installed():
        assert ssh(". /etc/os-release; printf %s $ID").stdout == "finix"
        assert ssh("readlink -f /proc/1/exe").stdout.strip() == "${target.config.finit.package}/bin/finit"
        assert ssh("findmnt -n -o FSTYPE /").stdout.strip() == "ext4"
        assert ssh("findmnt -n -o SOURCE /").stdout.strip().startswith("/dev/")
        ssh("test -d /sys/firmware/efi; test -f /boot/EFI/BOOT/BOOTX64.EFI")
        # A host store share would hide an incomplete closure copy.
        assert "9p" not in ssh("findmnt -n -o FSTYPE").stdout.split()
        assert "virtiofs" not in ssh("findmnt -n -o FSTYPE").stdout.split()
        for profile in ["/run/current-system", "/run/booted-system", "/nix/var/nix/profiles/system"]:
            assert ssh("readlink -f " + profile).stdout.strip() == "${system}"
        ssh("nix-store --check-validity ${system}")
        assert ssh("cat /var/lib/sshd/ssh_host_ed25519_key.pub").stdout.strip() == host_key
        assert ssh("stat -c %a /var/lib/sshd/ssh_host_ed25519_key").stdout.strip() == "600"
        assert ssh("cat /home/operator/.ssh/secret").stdout.strip() == "persistent-extra-file"
        assert ssh("stat -c %a /home/operator/.ssh/secret").stdout.strip() == "600"
        assert ssh("stat -c %u:%g /home/operator/.ssh/secret").stdout.strip() == "1000:100"
        assert ssh("stat -c %a /root/.ssh/authorized_keys").stdout.strip() == "600"
        assert ssh("stat -c %a /var/lib/credentials/operator-password").stdout.strip() == "600"
        shadow_hash = ssh("getent shadow operator | cut -d: -f2").stdout.strip()
        assert shadow_hash == ssh("cat /var/lib/credentials/operator-password").stdout.strip()
        assert ssh("id -u", user="operator", password=True).stdout.strip() == "1000"
        assert ssh("cat ~/.ssh/secret", user="operator").stdout.strip() == "persistent-extra-file"

    for boot in range(2):
        with subtest(f"UEFI disk-only boot {boot + 1}, with real authenticated SSH"):
            log_path = driver.out_dir / f"finix-boot-{boot + 1}.log"
            with log_path.open("w") as boot_log:
                process = subprocess.Popen(
                    [*qemu, "-serial", "stdio"], stdout=boot_log, stderr=subprocess.STDOUT,
                )
                try:
                    wait_for_ssh(process)
                    check_installed()
                    if boot == 0:
                        ssh("printf '%s\\n' survives-cold-boot > /var/lib/persistence-proof; sync")
                    else:
                        assert ssh("cat /var/lib/persistence-proof").stdout.strip() == "survives-cold-boot"
                    ssh("${target.config.finit.package}/bin/poweroff", check=False)
                    assert process.wait(timeout=60) == 0
                except Exception:
                    print(log_path.read_text())
                    raise
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
  '';
}).config.result
