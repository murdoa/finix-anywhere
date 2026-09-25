#!/bin/sh
# Runs as root on the source OS. Only the final nix-daemon path goes to stdout.
set -eu

if command -v nix-daemon >/dev/null 2>&1; then
  command -v nix-daemon
  exit 0
fi

test "$(id -u)" = 0 || { echo 'Nix bootstrap requires root' >&2; exit 1; }
version=2.31.2
case "$(uname -m)" in
  x86_64) hash=d1f67c86eed016214864ba08bfb9529c307aea7e8fafb74853f96fcc3bfd8a60 ;;
  aarch64) hash=64db528412096d718b4bf8f78f85e5ac2b714b774e5005500dee37d23f560456 ;;
  *) echo 'Native installer supports x86_64 and aarch64 Linux' >&2; exit 1 ;;
esac
archive="nix-$version-$(uname -m)-linux"
work=$(mktemp -d /tmp/finix-nix-bootstrap.XXXXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
url="https://releases.nixos.org/nix/nix-$version/$archive.tar.xz"
echo "Bootstrapping pinned Nix $version on the source OS (no OS transition)" >&2
if command -v curl >/dev/null 2>&1; then
  curl --fail --silent --show-error --location "$url" -o "$work/nix.tar.xz"
else
  wget -q "$url" -O "$work/nix.tar.xz"
fi
printf '%s  %s\n' "$hash" "$work/nix.tar.xz" | sha256sum --check >&2
tar -xJf "$work/nix.tar.xz" -C "$work"
mkdir -p /nix/store /nix/var/nix/gcroots
for path in "$work/$archive/store/"*; do
  if [ ! -e "/nix/store/${path##*/}" ]; then
    cp -a "$path" /nix/store/
  fi
done
set -- "$work/$archive/store/"*-nix-"$version"
test "$#" = 1 && test -d "$1"
nix="/nix/store/${1##*/}"
NIX_REMOTE=local "$nix/bin/nix-store" --option build-users-group '' --load-db <"$work/$archive/.reginfo"
ln -sfn "$nix" /nix/var/nix/gcroots/finix-anywhere-bootstrap
printf '%s\n' "$nix/bin/nix-daemon"
