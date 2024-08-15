#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)


function cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  echo "Cleaning Up"
}
trap cleanup SIGINT SIGTERM ERR EXIT

function main() {
  VMID="$(sudo pvesh get /cluster/nextid)"

  NODE="$(sudo pvesh get /nodes --output-format json | jq -r '.[].node' | gum choose --select-if-one --cursor="Select Node > ")"
  # NODE="falcon"
  echo "Selected ${NODE}"

  STORAGE="$(sudo pvesh get /nodes/${NODE}/storage --output-format json --human-readable true | jq -r '.[] | select((.enabled == 1) and (.content | contains("images"))).storage' | gum choose --select-if-one)"
  echo "Selected ${STORAGE} for storage"

  EXISTING_NODES=$(sudo pvesh get /nodes/${NODE}/qemu --output-format json | jq -r "map(.name | select(startswith(\"premhome-${NODE}\")))")

  printf "\nexisting Nodes: %s\n" "${EXISTING_NODES}"

  DEFAULT_NAME=$(jq -r "map(capture(\"(?<base>.*-)(?<num>[0-9]+)$\") | .num |= (tonumber + 1) | \"\(.base)\(.num)\") | max" <<< "$EXISTING_NODES")

  NAME="$(gum input --prompt="VM Name > " --value="${DEFAULT_NAME}")"
  echo "creating VM with id: ${VMID} on ${NODE} stored on ${STORAGE} with name: ${NAME}"
  sudo qm create "${VMID}" \
    --agent 1 \
    --bios "ovmf" \
    --boot "order=scsi0;ide2" \
    --cores 2 \
    --cpu "host" \
    --efidisk0 "${STORAGE}:1,efitype=4m" \
    --ide2 "local:iso/nixos-yadunut.iso,media=cdrom" \
    --machine q35 \
    --memory 2048 \
    --name "${NAME}" \
    --net0 "virtio,bridge=vmbr0" \
    --ostype "l26" \
    --scsi0 "${STORAGE}:50,iothread=on" \
    --scsihw "virtio-scsi-single"

  echo "Created VM, starting..."
  sudo qm start "${VMID}"
  echo "Started VM ${VMID}"

  echo "Attempting to retrieve IP Address"
  start_time=$(date +%s)
  while true; do
    if IP_ADDRESS="$(sudo qm agent "${VMID}" network-get-interfaces 2>/dev/null | jq -r '.[] | select(.name == "tailscale0") | .["ip-addresses"][] | select(.["ip-address-type"] == "ipv4")')"; then
      if [ -n "${IP_ADDRESS}" ]; then
        echo "Retrieved IP Address: ${IP_ADDRESS}"
        break
      fi
    fi

    echo "Failed to retrieve IP, trying again"

    current_time=$(date +%s)
    elapsed_time=$((current_time - start_time))

    if [ $elapsed_time -ge 60 ]; then
      echo "1 minute has elapsed. Failing"
      cleanup
      break
    fi

    sleep 3
  done
    # try to retrieve IP address
}

main "$@"
