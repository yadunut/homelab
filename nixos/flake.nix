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

  outputs = { flake-utils,nixpkgs, disko, agenix, nixos-generators, ... }: let
    nodes = ["premhome-falcon-1" "premhome-falcon-2"];
  in {
    packages = builtins.listToAttrs(map (system: {
      name=system;
      value={
        generate-iso = nixos-generators.nixosGenerate {
          format = "iso";
          system = "x86_64-linux";
          modules = [
            ./proxmox/iso.nix # base configuration of the image
          ];
        };
      };
      })
      ["x86_64-linux" "aarch64-darwin"]) //
      {
        x86_64-linux = {
        create-vm = let
          pkgs = import nixpkgs { system = "x86_64-linux"; };
          script-name = "create-vm";
          src = builtins.readFile ./proxmox/create-vm.sh;
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

        };
      };

  } // flake-utils.lib.eachDefaultSystem (system:
    let pkgs = import nixpkgs {
      inherit system;
    }; in
    {
      devShells = {
        default = pkgs.mkShell {
        buildInputs = with pkgs; [
          colmena
          shellcheck
        ];
      };
    };
  });
}
