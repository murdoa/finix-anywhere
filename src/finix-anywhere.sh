#!/usr/bin/env bash
set -euo pipefail

here=$(dirname "${BASH_SOURCE[0]}")
flake=""
flakeAttr=""
kexecUrl=""
forceKexec=false
kexecExtraFlags=""
sshStoreSettings="compress=true"
enableDebug=""
nixBuildFlags=()
diskoAttr=""
diskoScript=""
diskoMode=""
diskoDeps=y
nixosSystem=""
extraFiles=""
copyHostKeys=n
machineSystem=""
targetHostKeyPaths=()
substituters=""
trustedPublicKeys=""
nixOptions=(
  --extra-experimental-features 'nix-command flakes'
  "--no-write-lock-file"
)
SSH_PRIVATE_KEY=${SSH_PRIVATE_KEY-}
machineSubstituters="y"

declare -A phases
phases[kexec]=1
phases[disko]=1
phases[install]=1
phases[reboot]=1

sshPrivateKeyFile=
if [ -t 0 ]; then # stdin is a tty, we allow interactive input to ssh i.e. passwords
  sshTtyParam="-t"
else
  sshTtyParam="-T"
fi
sshConnection=
postKexecSshPort=22
buildOnRemote=n
buildOn=auto
envPassword=n

# Facts set by get-facts.sh
isOs=
isArch=
isInstaller=
isContainer=
isRoot=
hasIpv6Only=
hasTar=
hasCpio=
hasSudo=
hasDoas=
hasWget=
hasCurl=
hasSetsid=

tempDir=$(mktemp -d -t finix-anywhere.XXXXXXXXXX)
trap 'rm -rf "$tempDir"' EXIT
mkdir -p "$tempDir"

declare -A diskEncryptionKeys=()
declare -A extraFilesOwnership=()
declare -a nixCopyOptions=()
declare -a sshArgs=("-o" "IdentitiesOnly=yes" "-i" "$tempDir/finix-anywhere" "-o" "UserKnownHostsFile=/dev/null" "-o" "StrictHostKeyChecking=no")

showUsage() {
  cat <<USAGE
Usage: finix-anywhere [options] [<ssh-host>]

Options:

* -f, --flake <flake_uri>
  set the flake to install the system from. i.e.
  finix-anywhere --flake .#mymachine
  Also supports explicit configuration paths:
  finix-anywhere --flake .#nixosConfigurations.mymachine.config
* --target-host <ssh-host>
  set the SSH target host to deploy onto.
* -i <identity_file>
  selects which SSH private key file to use.
* -p, --ssh-port <ssh_port>
  set the ssh port to connect with
* --ssh-option <ssh_option>
  set one ssh option, no need for the '-o' flag, can be repeated.
  for example: '--ssh-option ServerAliveInterval=10'
* -L, --print-build-logs
  print full build logs
* --env-password
  set a password used by ssh-copy-id, the password should be set by
  the environment variable SSHPASS
* -s, --store-paths <disko-script> <finix-system>
  set the store paths to the disko-script and Finix system directly
  if this is given, flake is not needed
* --kexec <path>
  use another kexec tarball to bootstrap NixOS
* --force-kexec
  don't check if we're in the installer, run kexec anyway
* --kexec-extra-flags
  extra flags to add into the call to kexec, e.g. "--no-sync"
* --ssh-store-setting <key> <value>
  ssh store settings appended to the store URI, e.g. "compress true". <value> needs to be URI encoded.
* --post-kexec-ssh-port <ssh_port>
  after kexec is executed, use a custom ssh port to connect. Defaults to 22
* --copy-host-keys
  preserve the original ed25519 host key from /var/lib/sshd or /etc/ssh
  at the configured Finix HostKey paths, capturing it before kexec.
* --extra-files <path>
  contents of local <path> are recursively copied to the root (/) of the new Finix installation. Existing files are overwritten
  Copied files will be owned by root unless specified by --chown option. See documentation for details.
* --chown <path> <ownership>
  change ownership of <path> recursively. Recommended to use uid:gid as opposed to username:groupname for ownership.
  Option can be specified more than once.
* --disk-encryption-keys <remote_path> <local_path>
  copy the contents of the file or pipe in local_path to remote_path in the installer environment,
  after kexec but before installation. Can be repeated.
* --no-substitute-on-destination
  disable passing --substitute-on-destination to nix-copy
  implies --no-use-machine-substituters
* --no-use-machine-substituters
  don't copy the substituters from the machine to be installed into the installer environment
* --debug
  enable debug output
* --show-trace
  show nix build traces
* --option <key> <value>
  nix option to pass to every nix related command
* --from <store-uri>
  URL of the source Nix store to copy the Finix and disko closure from
* --build-on-remote
  build the closure on the remote machine instead of locally and copy-closuring it
* --phases
  comma separated list of phases to run. Default is: kexec,disko,install,reboot
  kexec: kexec into the NixOS installer
  disko: first unmount and destroy all filesystems on the disks we want to format, then run the create and mount mode
  install: install the system
  reboot: unmount the filesystems, export any ZFS pools and reboot the machine
* --disko-mode disko|mount|format
  set the disko mode to format, mount or destroy. Default is disko.
  disko: first unmount and destroy all filesystems on the disks we want to format, then run the create and mount mode
* --no-disko-deps
  This will only upload the disko script and not the partitioning tools dependencies.
  Installers usually have dependencies available.
  Use this option if your target machine has not enough RAM to store the dependencies in memory.
* --build-on auto|remote|local
  sets the build on settings to auto, remote or local. Default is auto.
  auto: tries to figure out, if the build is possible on the local host, if not falls back gracefully to remote build
  local: will build on the local host
  remote: will build on the remote host
USAGE
}

abort() {
  echo "aborted: $*" >&2
  exit 1
}

step() {
  echo "### $* ###"
}

parseArgs() {
  local substituteOnDestination=y
  local printBuildLogs=n
  local buildOnRemote=n
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -f | --flake)
      flake=$2
      shift
      ;;
    --target-host)
      sshConnection=$2
      shift
      ;;
    -i)
      sshPrivateKeyFile=$2
      shift
      ;;
    -p | --ssh-port)
      sshArgs+=("-p" "$2")
      shift
      ;;
    --ssh-option)
      sshArgs+=("-o" "$2")
      shift
      ;;
    -L | --print-build-logs)
      printBuildLogs=y
      ;;
    -s | --store-paths)
      diskoScript=$(readlink -f "$2")
      nixosSystem=$(readlink -f "$3")
      shift
      shift
      ;;
    --generate-hardware-config)
      abort "--generate-hardware-config is not supported for Finix. Supply a Finix hardware configuration in your flake; NixOS hardware generators do not produce compatible modules."
      ;;
    -t | --tty)
      echo "the '$1' flag is deprecated, a tty is now detected automatically" >&2
      ;;
    --help)
      showUsage
      exit 0
      ;;
    --kexec)
      kexecUrl=$2
      shift
      ;;
    --force-kexec)
      forceKexec=true
      shift
      ;;
    --kexec-extra-flags)
      kexecExtraFlags=$2
      shift
      ;;
    --ssh-store-setting)
      key=$2
      value=$3
      sshStoreSettings+="&$key=$value"
      shift
      shift
      ;;
    --post-kexec-ssh-port)
      postKexecSshPort=$2
      shift
      ;;
    --copy-host-keys)
      copyHostKeys=y
      ;;
    --show-trace)
      nixBuildFlags+=("--show-trace")
      ;;
    --debug)
      enableDebug="-x"
      printBuildLogs=y
      set -x
      ;;
    --disko-mode)
      case "$2" in
      format | mount | disko)
        diskoMode=$2
        ;;
      *)
        abort "Supported values for --disko-mode are disko, mount and format. Unknown mode : $2"
        ;;
      esac

      shift
      ;;
    --no-disko-deps)
      diskoDeps=n
      ;;
    --build-on)
      case "$2" in
      auto | local | remote)
        buildOn=$2
        ;;
      *)
        abort "Supported values for --build-on are auto, local and remote. Unknown mode : $2"
        ;;
      esac

      shift
      ;;
    --extra-files)
      extraFiles=$2
      shift
      ;;
    --chown)
      extraFilesOwnership["$2"]="$3"
      shift
      shift
      ;;
    --disk-encryption-keys)
      diskEncryptionKeys["$2"]="$3"
      shift
      shift
      ;;
    --phases)
      phases[kexec]=0
      phases[disko]=0
      phases[install]=0
      phases[reboot]=0
      IFS=, read -r -a phaseList <<<"$2"
      for phase in "${phaseList[@]}"; do
        if [[ ${phases[$phase]:-unset} == unset ]]; then
          abort "Unknown phase: $phase"
        fi
        phases[$phase]=1
      done
      shift
      ;;
    --stop-after-disko)
      echo "WARNING: --stop-after-disko is deprecated, use --phases kexec,disko instead" 2>&1
      phases[kexec]=1
      phases[disko]=1
      phases[install]=0
      phases[reboot]=0
      ;;
    --no-reboot)
      echo "WARNING: --no-reboot is deprecated, use --phases kexec,disko,install instead" 2>&1
      phases[kexec]=1
      phases[disko]=1
      phases[install]=1
      phases[reboot]=0
      ;;
    --from)
      nixCopyOptions+=("--from" "$2")
      shift
      ;;
    --option)
      key=$2
      shift
      value=$2
      shift
      nixOptions+=("--option" "$key" "$value")
      ;;
    --no-substitute-on-destination)
      substituteOnDestination=n
      machineSubstituters=n
      ;;
    --no-use-machine-substituters)
      machineSubstituters=n
      ;;
    --build-on-remote)
      echo "WARNING: --build-on-remote is deprecated, use --build-on remote instead" 2>&1
      buildOnRemote=y
      buildOn="remote"
      ;;
    --env-password)
      envPassword=y
      ;;
    --vm-test)
      abort "--vm-test is not supported for Finix. Run nix build .#checks.x86_64-linux.installation in the finix-anywhere source tree for the supported installation check."
      ;;
    *)
      if [[ -z ${sshConnection} ]]; then
        sshConnection="$1"
      else
        showUsage
        exit 1
      fi
      ;;
    esac
    shift
  done

  if [[ ${diskoMode} != "" ]]; then
    if [[ ${diskoScript} != "" ]]; then
      abort "--disko-mode cannot be used if --store-paths is used"
    fi
  else
    diskoMode=disko
  fi

  diskoAttr="${diskoMode}Script"

  if [[ ${diskoDeps} == "n" ]]; then
    diskoAttr="${diskoAttr}NoDeps"
  fi

  if [[ ${printBuildLogs} == "y" ]]; then
    nixOptions+=("-L")
  fi

  if [[ $substituteOnDestination == "y" ]]; then
    nixCopyOptions+=("--substitute-on-destination")
  fi

  if [[ -z ${sshConnection} ]]; then
    abort "ssh-host must be set"
  fi

  if [[ $buildOn == "local" ]] && [[ $buildOnRemote == "y" ]]; then
    abort "Conflicting flags: --build-on local and --build-on-remote used."
  fi

  if [[ -n ${flake} ]]; then
    if [[ $flake =~ ^(.*)\#([^\#\"]*)$ ]]; then
      flake="${BASH_REMATCH[1]}"
      flakeAttr="${BASH_REMATCH[2]}"
    fi
    if [[ -z ${flakeAttr} ]]; then
      echo "Please specify the name of the Finix configuration to be installed, as a URI fragment in the flake-uri." >&2
      echo 'For example, to use the output nixosConfigurations.foo from the flake.nix, append "#foo" to the flake-uri.' >&2
      exit 1
    fi

    # Support .#foo shorthand
    if [[ $flakeAttr != nixosConfigurations.* ]]; then
      flakeAttr="nixosConfigurations.\"$flakeAttr\".config"
    fi
  fi

}

preflight() {
  local metadata path
  if [[ -n ${flake} ]]; then
    if [[ -n ${nixosSystem} || -n ${diskoScript} ]]; then
      abort "--flake and --store-paths cannot be combined"
    fi
    if ! metadata=$(nix eval "${nixOptions[@]}" --json "${flake}#${flakeAttr}" --apply '
      config: builtins.seq config.system.build.toplevel.drvPath {
        deployment = config.boot.bootspec.extensions."org.finix-anywhere.v1" or null;
        system = config.nixpkgs.pkgs.stdenv.hostPlatform.system;
        substituters = builtins.toString (config.services.nix-daemon.settings.substituters or []);
        trustedPublicKeys = builtins.toString (config.services.nix-daemon.settings.trusted-public-keys or []);
      }
    '); then
      abort "Unable to evaluate the Finix deployment. Import finix-anywhere.nixosModules.default and supply a complete Finix hardware configuration."
    fi
  elif [[ -n ${diskoScript} && -n ${nixosSystem} ]]; then
    if [[ ! -e ${diskoScript} || ! -d ${nixosSystem} ]]; then
      abort "${diskoScript} and ${nixosSystem} must be existing store-paths"
    fi
    if [[ ! -f ${nixosSystem}/nixos-version ]] || [[ $(cat "${nixosSystem}/nixos-version") != finix ]]; then
      abort "--store-paths requires a Finix system closure (nixos-version must be finix)"
    fi
    for path in kernel initrd init activate sw/bin/bash; do
      if [[ ! -e ${nixosSystem}/${path} ]]; then
        abort "Finix system closure is missing ${path}; a bootable deployment is required"
      fi
    done
    if ! metadata=$(jq -c '{
      deployment: ."org.finix-anywhere.v1",
      system: ."org.nixos.bootspec.v1".system
    }' "${nixosSystem}/boot.json"); then
      abort "Unable to read the Finix deployment bootspec from ${nixosSystem}/boot.json"
    fi
  else
    abort "--flake or --store-paths must be set"
  fi

  if ! jq -e '
    (.deployment | type == "object") and
    (.deployment.bootloader | type == "string" and length > 0 and . != "none")
  ' <<<"$metadata" >/dev/null; then
    abort "Missing Finix deployment metadata or a real bootloader. Import finix-anywhere.nixosModules.default and configure a bootloader other than none."
  fi
  if ! jq -e '.system | type == "string" and test("^[a-zA-Z0-9_]+-[a-zA-Z0-9_]+$")' <<<"$metadata" >/dev/null; then
    abort "Finix deployment metadata is missing a valid host platform"
  fi
  machineSystem=$(jq -r '.system' <<<"$metadata")
  substituters=$(jq -r '.substituters // ""' <<<"$metadata")
  trustedPublicKeys=$(jq -r '.trustedPublicKeys // ""' <<<"$metadata")

  if [[ ${copyHostKeys} == y ]]; then
    if [[ ${phases[install]} != 1 ]]; then
      abort "--copy-host-keys requires the install phase so the captured identity can be preserved"
    fi
    if ! jq -e '.deployment.hostKeys | type == "array" and length > 0 and all(.[]; type == "string")' <<<"$metadata" >/dev/null; then
      abort "--copy-host-keys requires configured Finix OpenSSH HostKey paths in the deployment metadata"
    fi
    mapfile -t targetHostKeyPaths < <(jq -r '.deployment.hostKeys[]' <<<"$metadata")
    for path in "${targetHostKeyPaths[@]}"; do
      if [[ ! $path =~ ^/([[:alnum:]_.-]+/)*ssh_host_ed25519_key$ || $path == *"/../"* || $path == *"/./"* ]]; then
        abort "--copy-host-keys supports only absolute HostKey paths ending in ssh_host_ed25519_key; unsupported path: $path"
      fi
    done
  fi
}

# ssh wrapper
runSshNoTty() {
  # shellcheck disable=SC2029
  # We want to expand "$@" to get the command to run over SSH
  ssh -T "${sshArgs[@]}" "$sshConnection" "$@"
}
runSshTimeout() {
  timeout 10 ssh "${sshArgs[@]}" "$sshConnection" "$@"
}
runSsh() {
  (
    set +x
    if [[ -n ${enableDebug} ]]; then
      echo -e "\033[1;34mSSH COMMAND:\033[0m ssh $sshTtyParam ${sshArgs[*]} $sshConnection $*\n"
    fi
    # shellcheck disable=SC2029
    # We want to expand "$@" to get the command to run over SSH
    ssh "$sshTtyParam" "${sshArgs[@]}" "$sshConnection" "$@"
  )
}

nixCopy() {
  NIX_SSHOPTS="${sshArgs[*]}" nix copy \
    "${nixOptions[@]}" \
    "${nixCopyOptions[@]}" \
    "$@"
}
nixBuild() {
  NIX_SSHOPTS="${sshArgs[*]}" nix build \
    --print-out-paths \
    --no-link \
    "${nixBuildFlags[@]}" \
    "${nixOptions[@]}" \
    "$@"
}

captureHostKey() {
  step Capturing the original ed25519 SSH host identity before kexec
  if ! (
    umask 077
    # Do not allocate a tty: private-key bytes must not undergo terminal processing.
    runSshNoTty -o ConnectTimeout=10 "${maybeSudo} sh -s" >"$tempDir/ssh_host_ed25519_key" <<'SSH'
set -eu
for key in /var/lib/sshd/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key; do
  if [ -s "$key" ]; then
    cat "$key"
    exit 0
  fi
done
echo "No original ed25519 host key found in /var/lib/sshd or /etc/ssh" >&2
exit 1
SSH
  ); then
    abort "--copy-host-keys could not capture the original ed25519 host key; refusing to continue"
  fi
  if ! ssh-keygen -y -P "" -f "$tempDir/ssh_host_ed25519_key" >"$tempDir/ssh_host_ed25519_key.pub" ||
    ! grep -q '^ssh-ed25519 ' "$tempDir/ssh_host_ed25519_key.pub"; then
    abort "--copy-host-keys requires a readable, unencrypted ed25519 host key"
  fi
}

installHostKeys() {
  local path
  step Installing the captured ed25519 SSH host identity
  for path in "${targetHostKeyPaths[@]}"; do
    # Preflight restricts these paths to shell-safe absolute ed25519 key names.
    runSshNoTty "set -eu; umask 077; install -d -m 755 /mnt$(dirname "$path"); cat > /mnt$path; chmod 600 /mnt$path; chown 0:0 /mnt$path" <"$tempDir/ssh_host_ed25519_key"
    runSshNoTty "set -eu; cat > /mnt$path.pub; chmod 644 /mnt$path.pub; chown 0:0 /mnt$path.pub" <"$tempDir/ssh_host_ed25519_key.pub"
  done
}

uploadSshKey() {
  # ssh-copy-id requires this directory
  local sshCopyHome="$HOME"
  if ! mkdir -p "$HOME/.ssh/" 2>/dev/null; then
    # Fallback: create a temporary home directory for ssh-copy-id in tempDir
    sshCopyHome="$tempDir/ssh-home"
    mkdir -p "$sshCopyHome/.ssh"
    echo "Warning: Could not create $HOME/.ssh, using temporary directory: $sshCopyHome"
  fi

  if [[ -n ${sshPrivateKeyFile} ]]; then
    cp "$sshPrivateKeyFile" "$tempDir/finix-anywhere"
    ssh-keygen -y -f "$tempDir/finix-anywhere" >"$tempDir/finix-anywhere.pub"
  else
    # Generate a temporary SSH keypair for the installation session.
    ssh-keygen -t ed25519 -f "$tempDir"/finix-anywhere -P "" -C "finix-anywhere" >/dev/null
  fi

  step Uploading install SSH keys
  until
    if [[ ${envPassword} == y ]]; then
      HOME="$sshCopyHome" sshpass -e \
        ssh-copy-id \
        -o ConnectTimeout=10 \
        "${sshArgs[@]}" \
        "$sshConnection"
    else
      # To override `IdentitiesOnly=yes` set in `sshArgs` we need to set
      # `IdentitiesOnly=no` first as the first time an SSH option is
      # specified on the command line takes precedence
      HOME="$sshCopyHome" ssh-copy-id \
        -o IdentitiesOnly=no \
        -o ConnectTimeout=10 \
        "${sshArgs[@]}" \
        "$sshConnection"
    fi
  do
    sleep 3
  done
}

importFacts() {
  step Gathering machine facts
  local facts filteredFacts
  if ! facts=$(runSsh -o ConnectTimeout=10 enableDebug=$enableDebug sh -- <"$here"/get-facts.sh); then
    exit 1
  fi
  filteredFacts=$(echo "$facts" | grep -E '^(has|is|remote)[A-Za-z0-9_]+=\S+')
  if [[ -z $filteredFacts ]]; then
    abort "Retrieving host facts via SSH failed. Check with --debug for the root cause, unless you have done so already"
  fi

  # disable debug output temporarily to prevent log spam
  set +x

  # make facts available in script
  # shellcheck disable=SC2046
  export $(echo "$filteredFacts" | xargs)

  # Necessary to prevent Bash erroring before printing out which fact had an issue
  set +u
  for var in isOs isArch isInstaller isContainer isRoot hasIpv6Only hasTar hasCpio hasSudo hasDoas hasWget hasCurl hasSetsid; do
    if [[ -z ${!var} ]]; then
      abort "Failed to retrieve fact $var from host"
    fi
  done
  set -u

  if [[ -n ${enableDebug} ]]; then
    set -x
  fi

  if [[ ${isRoot} == "y" ]]; then
    maybeSudo=
  elif [[ ${hasSudo} == "y" ]]; then
    maybeSudo=sudo
  elif [[ ${hasDoas} == "y" ]]; then
    maybeSudo=doas
  else
    # shellcheck disable=SC2016
    abort 'Unable to find a command to use to escalate privileges: Could not find `sudo` or `doas`'
  fi
}

checkBuildLocally() {
  local system extraPlatforms
  system="$(nix --extra-experimental-features 'nix-command flakes' config show system)"
  extraPlatforms="$(nix --extra-experimental-features 'nix-command flakes' config show extra-platforms)"

  if [[ ${system} == "${machineSystem}" ]]; then
    buildOn=local
    return
  fi

  if [[ " ${extraPlatforms} " == *" ${machineSystem} "* ]]; then
    buildOn=local
    return
  fi

  local entropy
  entropy="$(date +'%Y%m%d%H%M%S')"

  if nix build \
    -L \
    "${nixOptions[@]}" \
    --expr \
    "derivation { system = \"$machineSystem\"; name = \"env-$entropy\"; builder = \"/bin/sh\"; args = [ \"-c\" \"echo > \$out\" ]; }"; then
    # A configured builder can build this platform.
    buildOn=local
    return
  fi

  buildOn=remote
}

runKexec() {
  if [[ ${isInstaller} == "y" ]] && [[ ${forceKexec} != "true" ]]; then
    return
  fi

  if [[ ${isContainer} != "none" ]]; then
    echo "WARNING: This script does not support running from a '${isContainer}' container. kexec will likely not work" >&2
  fi

  if [[ $kexecUrl == "" ]]; then
    case "${isArch}" in
    x86_64 | aarch64)
      kexecUrl="https://github.com/nix-community/nixos-images/releases/download/nixos-25.11/nixos-kexec-installer-noninteractive-${isArch}-linux.tar.gz"
      ;;
    *)
      abort "Unsupported architecture: ${isArch}. Our default kexec images only support x86_64 and aarch64 CPUs. Check out https://nix-community.github.io/nixos-anywhere/howtos/custom-kexec.html for more information."
      ;;
    esac
  fi

  step Switching system into kexec

  # no way to reach global ipv4 destinations, use gh-v6.com automatically if github url
  if [[ ${hasIpv6Only} == "y" ]] && [[ $kexecUrl == "https://github.com/"* ]]; then
    kexecUrl=${kexecUrl/"github.com"/"gh-v6.com"}
  fi

  # Handle kexec operation failures
  handleKexecFailure() {
    local operation=$1

    # Try to fetch the log file
    local logContent=""
    if logContent=$(
      set +x
      # shellcheck disable=SC2016 # We want $HOME to expand on the remote server
      runSsh 'cat "$HOME/kexec/finix-anywhere.log" 2>/dev/null' 2>/dev/null
    ); then
      echo "Remote output log:" >&2
      echo "$logContent" >&2
    fi
    echo "$operation failed" >&2
    exit 1
  }

  # Define common remote commands template
  local remoteCommandTemplate
  remoteCommandTemplate="
# Run kexec commands with sudo if needed
{
  set -eu ${enableDebug}
  cd \"\$HOME/kexec\"
  echo Downloading kexec tarball, this may take a moment...
  # Execute tar command
  %TAR_COMMAND%
  TMPDIR=\"\$HOME/kexec\" ${maybeSudo} setsid --wait \"\$HOME/kexec/kexec/run\" --kexec-extra-flags $(printf '%q' "$kexecExtraFlags")
} 2>&1 | tee \"\$HOME/kexec/finix-anywhere.log\" || true

# The script will likely disconnect us, so we consider it successful if we see the kexec message
if ! grep -q 'machine will boot into nixos' \"\$HOME/kexec/finix-anywhere.log\"; then
  echo 'Kexec may have failed - check output above'
  exit 1
fi
"

  # Define upload commands
  local localUploadCommand=()
  local remoteUploadCommand=()

  # gnu tar cannot automatically detect the compression when decompressing via stdin
  tarDecomp=""
  if [[ ${kexecUrl} =~ \.tar\.gz$ ]]; then
    tarDecomp="--gzip"
  elif [[ ${kexecUrl} =~ \.tar\.xz$ ]]; then
    tarDecomp="--xz"
  elif [[ ${kexecUrl} =~ \.tar\.zst$ ]]; then
    tarDecomp="--zstd"
  elif [[ ${kexecUrl} =~ \.tar$ ]]; then
    tarDecomp=""
  fi

  if [[ -f $kexecUrl ]]; then
    localUploadCommand=(cat "$kexecUrl")
  elif [[ $hasWget == "y" ]]; then
    remoteUploadCommand=(wget "$kexecUrl" -O-)
  elif [[ $hasCurl == "y" ]]; then
    remoteUploadCommand=(curl --fail -Ss -L "$kexecUrl")
  else
    # Fallback to local curl
    localUploadCommand=(curl --fail -Ss -L "${kexecUrl}")
  fi

  # Determine the tar command based on upload method
  local tarCommand
  if [[ ${#localUploadCommand[@]} -eq 0 ]]; then
    # Use remote command for download
    tarCommand="$(printf '%q ' "${remoteUploadCommand[@]}") | tar -xv ${tarDecomp}"
  else
    # Use local file for extraction
    tarCommand="cat \"\$HOME/kexec/kexec-tarball.tar.gz\" | tar -xv ${tarDecomp}"
  fi

  local remoteCommands
  remoteCommands=${remoteCommandTemplate//'%TAR_COMMAND%'/$tarCommand}

  # Create and execute the script on the remote system
  # shellcheck disable=SC2016 # We want $HOME to expand on the remote server
  runSsh 'mkdir -p "$HOME/kexec" && cat > "$HOME/kexec/finix-anywhere-kexec.sh"' <<EOF
$remoteCommands
EOF
  if [[ ${#localUploadCommand[@]} -gt 0 ]]; then
    # Upload the kexec tarball first
    # shellcheck disable=SC2016 # We want $HOME to expand on the remote server
    "${localUploadCommand[@]}" | runSsh 'cat > "$HOME/kexec/kexec-tarball.tar.gz"'
  fi
  # shellcheck disable=SC2016 # We want $HOME to expand on the remote server
  runSsh 'bash "$HOME/kexec/finix-anywhere-kexec.sh"' || handleKexecFailure "Kexec"

  # use the default SSH port to connect at this point
  local i
  for i in "${!sshArgs[@]}"; do
    if [[ ${sshArgs[i]} == "-p" ]]; then
      sshArgs[i + 1]=$postKexecSshPort
      break
    fi
  done

  # wait for machine to become unreachable.
  while runSshTimeout -- exit 0; do sleep 1; done

  # After kexec we explicitly set the user to root@
  sshConnection="root@${sshHost}"

  # waiting for machine to become available again
  until runSsh -o ConnectTimeout=10 -- exit 0; do sleep 5; done

  importFacts

  if [[ ${isInstaller} == "n" ]]; then
    abort "Failed to kexec into NixOS installer"
  fi
}

runDisko() {
  local diskoScript=$1
  for path in "${!diskEncryptionKeys[@]}"; do
    step "Uploading ${diskEncryptionKeys[$path]} to $path"
    runSsh "umask 077; mkdir -p \"$(dirname "$path")\"; cat > $path" <"${diskEncryptionKeys[$path]}"
  done
  if [[ -n ${diskoScript} ]]; then
    nixCopy --to "ssh://$sshConnection?$sshStoreSettings" "$diskoScript"
  elif [[ ${buildOn} == "remote" ]]; then
    step Building disko script
    diskoScript=$(
      nixBuild "${flake}#${flakeAttr}.system.build.${diskoAttr}" \
        --eval-store auto --store "ssh-ng://$sshConnection?ssh-key=$tempDir%2Ffinix-anywhere&$sshStoreSettings"
    )
  fi

  local executable=disko
  case "$diskoMode" in
    format | mount) executable="disko-$diskoMode" ;;
  esac
  step "Running disko ($diskoMode)"
  runSsh sh -s -- "$diskoScript" "$executable" <<'SSH'
set -eu
if [ -d "$1" ]; then
  exec "$1/bin/$2"
else
  exec "$1"
fi
SSH
}

finixInstall() {
  local nixosSystem=$1
  if [[ -n ${nixosSystem} ]]; then
    step Uploading the system closure
    nixCopy --to "ssh://$sshConnection?remote-store=local%3Froot=%2Fmnt&$sshStoreSettings" "$nixosSystem"
  elif [[ ${buildOn} == "remote" ]]; then
    step Building the system closure
    nixosSystem=$(
      nixBuild "${flake}#${flakeAttr}.system.build.toplevel" \
        --eval-store auto --store "ssh-ng://$sshConnection?ssh-key=$tempDir%2Ffinix-anywhere&remote-store=local%3Froot=%2Fmnt&$sshStoreSettings"
    )
  fi

  if [[ -n ${extraFiles} ]]; then
    step Copying extra files
    tar -C "$extraFiles" -cpf- . | runSsh "tar -C /mnt -xf- --no-same-owner"

    runSsh "chmod 755 /mnt" # tar also changes permissions of /mnt
  fi

  if [[ ${#extraFilesOwnership[@]} -gt 0 ]]; then
    # shellcheck disable=SC2016
    printf "%s\n" "${!extraFilesOwnership[@]}" "${extraFilesOwnership[@]}" | pr -2t | runSsh 'while read file ownership; do chown -R "$ownership" "/mnt/$file"; done'
  fi

  if [[ ${copyHostKeys} == y ]]; then
    installHostKeys
  fi

  step Installing Finix
  runSsh sh <<SSH
set -eu ${enableDebug}
# when running not in nixos we might miss this directory, but it's needed in the nixos chroot during installation
export PATH="\$PATH:/run/current-system/sw/bin"

if [ ! -d "/mnt/tmp" ]; then
  # needed for installation if initrd-secrets are used
  mkdir -p /mnt/tmp
  chmod 777 /mnt/tmp
fi

# https://stackoverflow.com/a/13864829
if [ ! -z ${NIXOS_NO_CHECK+0} ]; then
  export NIXOS_NO_CHECK
fi
nixos-install --no-root-passwd --no-channel-copy --system "$nixosSystem"
SSH

}

requestReboot() {
  step Rebooting
  runSsh sh <<SSH
  if command -v zpool >/dev/null && [ "\$(zpool list)" != "no pools available" ]; then
    # we always want to export the zfs pools so people can boot from it without force import
    umount -Rv /mnt/
    swapoff -a
    zpool export -a || true
  fi
  nohup sh -c 'sleep 6 && reboot' >/dev/null 2>&1 &
SSH

  step Waiting for the machine to become unreachable due to reboot
  while runSshTimeout -- exit 0; do sleep 1; done
}

main() {
  parseArgs "$@"

  preflight

  if [[ ${buildOn} == "auto" ]]; then
    checkBuildLocally
  fi

  # Build locally before connecting; remote builds retain the preflight-validated config.
  if [[ -n ${flake} ]]; then
    if [[ ${buildOn} == "local" ]]; then
      if [[ ${phases[disko]} == 1 ]]; then
        diskoScript=$(nixBuild "${flake}#${flakeAttr}.system.build.${diskoAttr}")
      fi
      if [[ ${phases[install]} == 1 ]]; then
        nixosSystem=$(nixBuild "${flake}#${flakeAttr}.system.build.toplevel")
      fi
    fi
  fi

  if [[ -n ${SSH_PRIVATE_KEY} ]] && [[ -z ${sshPrivateKeyFile} ]]; then
    # $tempDir is getting deleted on trap EXIT
    sshPrivateKeyFile="$tempDir/from-env"
    (
      umask 077
      printf '%s\n' "$SSH_PRIVATE_KEY" >"$sshPrivateKeyFile"
    )
  fi

  sshSettings=$(ssh "${sshArgs[@]}" -G "${sshConnection}")
  sshUser=$(echo "$sshSettings" | awk '/^user / { print $2 }')
  sshHost="${sshConnection//*@/}"

  # If kexec phase is not present, we assume kexec has already been run
  # and change the user to root@<sshHost> for the rest of the script.
  if [[ ${phases[kexec]} != 1 ]]; then
    sshConnection="root@${sshHost}"
  fi

  uploadSshKey

  importFacts

  if [[ ${hasTar-n} == "n" ]]; then
    abort "no tar command found, but required to unpack kexec tarball"
  fi

  if [[ ${hasCpio-n} == "n" ]]; then
    abort "no cpio command found, but required to build the new initrd"
  fi

  if [[ ${hasSetsid-n} == "n" ]]; then
    abort "no setsid command respecting --wait found, but required to run the kexec script under a new session"
  fi

  if [[ ${isOs} != "Linux" ]]; then
    abort "This script requires Linux as the operating system, but got $isOs"
  fi

  if [[ ${copyHostKeys} == y ]]; then
    captureHostKey
  fi

  if [[ ${phases[kexec]} == 1 ]]; then
    runKexec
  fi

  # Installation will fail if non-root user is used for installer.
  # Switch to root user by copying authorized_keys.
  if [[ ${isInstaller} == "y" ]] && [[ ${sshUser} != "root" ]]; then
    # Allow copy to fail if authorized_keys does not exist, like if using /etc/ssh/authorized_keys.d/
    runSsh "${maybeSudo} mkdir -p /root/.ssh; ${maybeSudo} cp ~/.ssh/authorized_keys /root/.ssh || true"
    sshConnection="root@${sshHost}"
  fi

  # Get substituters from the machine and add them to the installer
  if [[ ${machineSubstituters} == "y" && -n ${flake} ]]; then
    # Finix's daemon module is optional; preflight defaults missing settings to empty.
    runSsh sh <<SSH || true
mkdir -p ~/.config/nix
echo "extra-substituters = ${substituters}" >> ~/.config/nix/nix.conf
echo "extra-trusted-public-keys = ${trustedPublicKeys}" >> ~/.config/nix/nix.conf
SSH
  fi

  if [[ ${phases[disko]} == 1 ]]; then
    runDisko "$diskoScript"
  fi

  if [[ ${phases[install]} == 1 ]]; then
    finixInstall "$nixosSystem"
  fi

  if [[ ${phases[reboot]} == 1 ]]; then
    requestReboot
  fi

  step "Requested installation phases completed; reboot requested: $([[ ${phases[reboot]} == 1 ]] && echo yes || echo no). Boot readiness has not been verified."
}

main "$@"
