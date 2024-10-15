{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils = {
      url = "github:numtide/flake-utils";
    };
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, flake-utils,nixpkgs, nixos-generators, disko, agenix, ... }: {
    nixosConfigurations = let
      nodes = import ./server/nodes.nix;
    in builtins.mapAttrs (name: data: nixpkgs.lib.nixosSystem {
        specialArgs = { meta = { hostname = name; ip = data.ip; private-ip = data.private-ip; }; };
        modules = [
          disko.nixosModules.disko
          agenix.nixosModules.default
          ./server/proxmox/disko-config.nix
          ./server/proxmox/configuration.nix
          ./server/proxmox/hardware-configuration.nix
        ];
      }) nodes;

    colmena = let
      configs = self.nixosConfigurations;
    in {
        meta = {
          description = "My personal machines";
          nixpkgs = import nixpkgs { system = "x86_64-linux"; };
          nodeNixpkgs = builtins.mapAttrs (name: value: value.pkgs) configs;
          nodeSpecialArgs = builtins.mapAttrs (name: value: value._module.specialArgs) configs;
        };
      } // builtins.mapAttrs (name: value: { 
      imports = value._module.args.modules; 
      deployment.targetHost = value._module.specialArgs.meta.private-ip; }) configs;
  };
}
