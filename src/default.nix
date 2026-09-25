{ stdenv
, openssh
, gitMinimal
, nix
, coreutils
, curl
, gnugrep
, gnutar
, gawk
, findutils
, gnused
, sshpass
, jq
, shellcheck
, lib
, makeWrapper
, mkShellNoCC
, installerFlake
}:
let
  runtimeDeps = [
    gitMinimal # for git flakes
    nix
    coreutils
    curl # when uploading tarballs
    gnugrep
    gawk
    findutils
    gnused # needed by ssh-copy-id
    sshpass # used to provide password for ssh-copy-id
    gnutar # used to upload extra-files
    jq
  ];
in
stdenv.mkDerivation {
  pname = "finix-anywhere";
  version = "0.1.0";
  src = ./.;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    install -D --target-directory=$out/libexec/finix-anywhere/ -m 0755 *.sh

    # We prefer the system's openssh over our own, since it might come with features not present in ours:
    # https://github.com/nix-community/nixos-anywhere/issues/62
    makeShellWrapper $out/libexec/finix-anywhere/finix-anywhere.sh $out/bin/finix-anywhere \
      --set FINIX_ANYWHERE_FLAKE ${lib.escapeShellArg "path:${toString installerFlake}"} \
      --prefix PATH : ${lib.makeBinPath runtimeDeps} --suffix PATH : ${lib.makeBinPath [ openssh ]}
  '';

  # Dependencies for our devshell
  passthru.devShell = mkShellNoCC {
    packages = runtimeDeps ++ [ openssh shellcheck ];
  };

  meta = with lib; {
    description = "Install Finix over SSH using a native Finix RAM installer";
    license = licenses.mit;
    mainProgram = "finix-anywhere";
    platforms = platforms.unix;
  };
}
