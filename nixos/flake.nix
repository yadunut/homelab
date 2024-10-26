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

  outputs = {
    self,
    nixpkgs,
    disko,
    agenix,
    ...
  }: {
    formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.alejandra;
    formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.alejandra;
    packages.aarch64-darwin = {
      setup-vm = let
        pkgs = import nixpkgs {system = "aarch64-darwin";};
        script-name = "setup-vm";
        src = builtins.readFile ./proxmox/setup-vm.sh;
        script = (pkgs.writeScriptBin script-name src).overrideAttrs (old: {
          buildCommand = "${old.buildCommand}\n patchShebangs $out";
        });
        buildInputs = with pkgs; [
          gum
          agenix.packages.aarch64-darwin.default
        ];
      in
        pkgs.symlinkJoin {
          name = script-name;
          paths = [script] ++ buildInputs;
          nativeBuildInputs = with pkgs; [makeWrapper];
          postBuild = "wrapProgram $out/bin/${script-name} --prefix PATH : $out/bin";
        };
    };
    nixosConfigurations = let
      nodes = import ./server/nodes.nix;
    in
      builtins.mapAttrs (name: data:
        nixpkgs.lib.nixosSystem {
          specialArgs = {
            meta = {
              hostname = name;
              private-ip = data.private-ip;
              server-addr = (import ./server/nodes.nix).premhome-gc1.zt-ip;
              role = data.role;
            };
          };
          modules = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./server/proxmox/disko-config.nix
            ./server/proxmox/configuration.nix
            ./server/proxmox/hardware-configuration.nix
          ];
        })
      nodes
      // {
        premhome-gc1 = nixpkgs.lib.nixosSystem {
          specialArgs.meta = (import ./server/nodes.nix).premhome-gc1;
          modules = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./server/premhome-gc1/disko-config.nix
            ./server/premhome-gc1/configuration.nix
            ./server/premhome-gc1/hardware-configuration.nix
          ];
        };
      };

    colmena = let
      configs = self.nixosConfigurations;
    in
      {
        meta = {
          description = "My personal machines";
          nixpkgs = import nixpkgs {system = "x86_64-linux";};
          nodeNixpkgs = builtins.mapAttrs (name: value: value.pkgs) configs;
          nodeSpecialArgs = builtins.mapAttrs (name: value: value._module.specialArgs) configs;
        };
      }
      // builtins.mapAttrs (name: value: {
        imports = value._module.args.modules;
        deployment.targetHost = value._module.specialArgs.meta.private-ip;
      })
      configs;
  };
}
