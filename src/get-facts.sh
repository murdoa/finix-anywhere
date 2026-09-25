#!/bin/sh
set -efu "${enableDebug:-}"
has() {
  command -v "$1" >/dev/null && echo "y" || echo "n"
}
isFinix=$(if test -f /etc/os-release && grep -Eq '^ID="?finix"?$' /etc/os-release; then echo "y"; else echo "n"; fi)
cat <<FACTS
isOs=$(uname)
isArch=$(uname -m)
isInstaller=$(if [ "$isFinix" = "y" ] && [ "$(cat /etc/finix-installer 2>/dev/null)" = 1 ]; then echo "y"; else echo "n"; fi)
isContainer=$(if [ "$(has systemd-detect-virt)" = "y" ]; then systemd-detect-virt --container; else echo "none"; fi)
isRoot=$(if [ "$(id -u)" -eq 0 ]; then echo "y"; else echo "n"; fi)
hasTar=$(has tar)
hasSudo=$(has sudo)
hasDoas=$(has doas)
hasSetsid=$(if [ "$(has setsid)" = "y" ] && setsid --wait true 2>/dev/null; then echo "y"; else echo "n"; fi)
FACTS
