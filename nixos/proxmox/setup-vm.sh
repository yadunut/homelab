#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
tmp_dir=$(mktemp -d)

function cleanup() {
  trap - SIGINT SIGTERM ERR EXIT

  echo "Cleaning Up"

  rm -rf "${tmp_dir}"
}
trap cleanup SIGINT SIGTERM ERR EXIT

function main() {
  if [ ! -e "./flake.nix" ]; then
    echo "Run this from within the homelab directory"
  fi

  # Get Machine Name: 
  MACHINE_NAME=$(gum input --prompt="Machine Name: >")
  MACHINE_IP=$(gum input --prompt="Machne IP: >")

  echo "Connecting to ${MACHINE_IP} and setting up as ${MACHINE_NAME}"
  #
  # Check if its ISO (check hostname == nixos)
  # Generate Host Public / Private Key Pair
  install -d -m755 "${tmp_dir}/etc/ssh" 
  KEY_PATH="${tmp_dir}/etc/ssh/ssh_host_ed25519_key"
  ssh-keygen -t ed25519 -C "yadunut@${MACHINE_NAME}" -f "${KEY_PATH}" -N ""


  echo "Created SSH Keys: $(cat "${KEY_PATH}".pub)"

  chmod 600 "${KEY_PATH}"

  # Append public key to the secrets file and rekey agenix
  pushd "./nixos/secrets"
  LINE="  ${MACHINE_NAME} = \"$(cat "${KEY_PATH}".pub)\";"
  echo "appending to file ${PWD}./keys.nix"
  sed -i -e "\$i${LINE}" "./keys.nix"
  agenix --rekey  
  popd
  # Deploy the systems!
  nix run github:nix-community/nixos-anywhere -- --flake ".#${MACHINE_NAME}" --extra-files "${tmp_dir}" --print-build-logs yadunut@${MACHINE_IP}
}

main "$@"
