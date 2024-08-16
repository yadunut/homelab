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

  outputs = { flake-utils,nixpkgs, nixos-generators, disko, agenix, ... }: {
    packages.x86_64-linux = {
      create-vm = let
        pkgs = import nixpkgs { system = "x86_64-linux"; };
        script-name = "create-vm";
        src = builtins.readFile ./nixos/proxmox/create-vm.sh;
        script = (pkgs.writeScriptBin script-name src).overrideAttrs(old: {
          buildCommand = "${old.buildCommand}\n patchShebangs $out";
        });
        buildInputs = with pkgs; [ gum jq ];
        in pkgs.symlinkJoin {
          name = script-name;
          paths = [ script ] ++ buildInputs;
          nativeBuildInputs = with pkgs; [makeWrapper];
          postBuild = "wrapProgram $out/bin/${script-name} --prefix PATH : $out/bin";
      };
      generate-iso = nixos-generators.nixosGenerate {
        format = "iso";
        system = "x86_64-linux";
        modules = [
          ./nixos/proxmox/iso.nix # base configuration of the image
        ];
      };
    };

    packages.aarch64-darwin = {
      setup-vm = let
        pkgs = import nixpkgs { system = "aarch64-darwin"; };
        script-name = "setup-vm";
        src = builtins.readFile ./nixos/proxmox/setup-vm.sh;
        script = (pkgs.writeScriptBin script-name src).overrideAttrs(old: {
            buildCommand = "${old.buildCommand}\n patchShebangs $out";
            });
      buildInputs = with pkgs; [ 
        gum 
        agenix.packages.aarch64-darwin.default
        ];
      in pkgs.symlinkJoin {
        name = script-name;
        paths = [ script ] ++ buildInputs;
        nativeBuildInputs = with pkgs; [makeWrapper];
        postBuild = "wrapProgram $out/bin/${script-name} --prefix PATH : $out/bin";
      };
    };

    nixosConfigurations = let
    nodes = ["premhome-falcon-1" "premhome-falcon-2"];
    in builtins.listToAttrs (map (name: {
      name = name;
      value = nixpkgs.lib.nixosSystem {
        specialArgs = { meta = { hostname = name; }; };
        modules = [
        disko.nixosModules.disko
        agenix.nixosModules.default
        ./nixos/server/disko-config.nix
        ./nixos/server/configuration.nix
        ./nixos/server/hardware-configuration.nix
        ];
      };
    }) nodes);

  } // flake-utils.lib.eachDefaultSystem (system:
    let pkgs = import nixpkgs {
      inherit system;
    }; in
    {
      devShells = {
        default = pkgs.mkShell {
        buildInputs = [
          pkgs.colmena
          pkgs.shellcheck
          agenix.packages.${system}.default
        ];
      };
    };
  });
}
