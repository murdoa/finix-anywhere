set -euo pipefail

state=/var/lib/finix-installer/network
[[ -d $state ]] || exit 0

for saved in "$state"/*; do
  [[ -d $saved ]] || continue
  mac=${saved##*/}
  interface=
  # Coldplug can finish while a driver is still completing device discovery.
  for ((attempt = 0; attempt < 30; attempt++)); do
    for device in /sys/class/net/*; do
      [[ -r $device/address ]] || continue
      if [[ $(<"$device/address") == "$mac" ]]; then
        interface=${device##*/}
        break
      fi
    done
    [[ -z $interface ]] || break
    sleep 1
  done
  if [[ -z $interface ]]; then
    echo "finix-installer: missing network device with MAC $mac" >&2
    exit 1
  fi

  ip link set dev "$interface" mtu "$(<"$saved/mtu")" up
  while IFS= read -r address; do
    ip -4 address replace "$address" dev "$interface"
  done < <(jq -r '.[].addr_info[] | select(.family == "inet" and .scope == "global") | "\(.local)/\(.prefixlen)"' "$saved/addresses.json")
  while IFS= read -r address; do
    # The address was usable on this very NIC before kexec. Skipping DAD avoids
    # an interval where its restored default route has no usable source.
    ip -6 address replace "$address" dev "$interface" nodad
  done < <(jq -r '.[].addr_info[] | select(.family == "inet6" and .scope == "global" and .preferred_life_time != 0) | "\(.local)/\(.prefixlen)"' "$saved/addresses.json")

  for family in 4 6; do
    while IFS= read -r route; do
      mapfile -t fields < <(jq -r '[.dst // "default", .gateway // "", .prefsrc // "", (.metric // "" | tostring), .scope // "", ((.flags // []) | index("onlink") != null)][]' <<< "$route")
      args=("${fields[0]}" dev "$interface")
      [[ -z ${fields[1]} ]] || args+=(via "${fields[1]}")
      [[ -z ${fields[2]} ]] || args+=(src "${fields[2]}")
      [[ -z ${fields[3]} ]] || args+=(metric "${fields[3]}")
      [[ -z ${fields[4]} || ${fields[4]} == global ]] || args+=(scope "${fields[4]}")
      [[ ${fields[5]} != true ]] || args+=(onlink)
      ip -"$family" route replace "${args[@]}"
    done < <(jq -c 'sort_by(has("gateway"))[] | select((.type // "unicast") == "unicast" and .protocol != "kernel")' "$saved/routes$family.json")
  done
done
