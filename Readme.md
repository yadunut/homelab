# Homelab
A quick guide on setting up new VMs / Servers in the Homelab with proxmox.
## Pre-Requisites
1. A tailscale setup, with a preauthkey with a long expiry. This will be baked into the nixos ISO for easy access to new VMs
# Install Guide

1. Generate ISO

This is to be run on the proxmox node. 

```bash
nix build --refresh "git+https://gitea.ts.yadunut.com/yadunut/homelab.git#generate-iso"
```
Copy ISO Over to the VM
```bash
cp ./result/iso/nixos-yadunut.iso /var/lib/vz/template/iso
```

2. Create virtual machines on proxmox

This command is to be run on the proxmox Node / via SSH. Follow the guide to setup the VM.

TODO: This currently only works on falcon, to support other nodes, I need to create new VMs via the API with `pvesh` instead of the `qm` tool. 
```bash
nix run --refresh --verbose "git+https://gitea.ts.yadunut.com/yadunut/homelab.git?ref=main#create-vm"
```
Copy the IP address 

3. Use nixos-anywhere to bootstrap virtual machines

```bash
nix run ".#bootstrap"`
```

# Process to creating a New Machine
1. Create an ISO and transfer it over to Proxmox if it doesn't already exist
2. Create the VMs on Proxmox with the `nix run "git+https://gitea.ts.yadunut.com/yadunut/homelab.git#create-vm"` command
3. Create the machine configuration in `./nixos/machines`
4. With NixOS anywhere, 

# Problem
I want to copy the tailscale key over to the newly initialized VMs. I guess the VMs don't need to have tailscale setup on launch of the ISO unless I bake it into the ISO :thinking:

Wait I could bake it into the ISO. 

It has been baked into the ISO. So now, I can connect to the VM from without being in the same network :)

Now that I have VMs booted into the ISO, I need to setup the VMs. This would firstly require:
1. Generating the host keys
2. Tailscale encrypt with age, and transfer to the VM
3. Encrypting

## Flux
```bash
flux bootstrap gitea --owner=yadunut --repository=homelab --hostname=gitea.ts.yadunut.com --path flux
```

## Give Ups
1. Gave up on attempting SDN with DHCP on proxmox
2. 

# Notes

Why the fuck are there 2 kustomizations
https://fluxcd.io/flux/faq/#are-there-two-kustomization-types
