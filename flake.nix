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

  outputs =
    {
      flake-utils,
      nixpkgs,
      nixos-generators,
      agenix,
      ...
    }:
    {
      packages.x86_64-linux = {
        create-vm =
          let
            pkgs = import nixpkgs { system = "x86_64-linux"; };
            script-name = "create-vm";
            src = builtins.readFile ./nixos/proxmox/create-vm.sh;
            script = (pkgs.writeScriptBin script-name src).overrideAttrs (old: {
              buildCommand = "${old.buildCommand}\n patchShebangs $out";
            });
            buildInputs = with pkgs; [
              gum
              jq
            ];
          in
          pkgs.symlinkJoin {
            name = script-name;
            paths = [ script ] ++ buildInputs;
            nativeBuildInputs = with pkgs; [ makeWrapper ];
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

    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        fluxOverlay = (
          final: prev:
          let
            version = "2.7.1";
            srcHash = "sha256-UJiH6dunTKrHtjc1FudyGugSAJYrBC7TMQp+3PdywPI=";
            manifestsHash = "sha256-/57wRJ2Sj5vkPsuDQp4q+gbs6C4Qy1PfS3KNt2I5IlU=";
            vendorHash = "sha256-C5s+/OwZ3cjJZmj39j69LJS3qwQXGJuxyRK1vHVgXGg=";

            manifests = prev.fetchzip {
              url = "https://github.com/fluxcd/flux2/releases/download/v${version}/manifests.tar.gz";
              # First build with a dummy, then replace with the `got:` hash from the error
              hash = manifestsHash;
              stripRoot = false;
            };
          in
          {
            fluxcd = prev.fluxcd.overrideAttrs (old: {
              inherit version vendorHash;
              src = prev.fetchFromGitHub {
                owner = "fluxcd";
                repo = "flux2";
                rev = "v${version}";
                # First build with a dummy, then replace with the `got:` hash
                hash = srcHash;
              };
              postUnpack = ''
                cp -r ${manifests} source/cmd/flux/manifests
                # disable tests that require network access
                rm source/cmd/flux/create_secret_git_test.go
              '';

              ldflags = [
                "-s"
                "-w"
                "-X main.VERSION=${version}"
              ];

              # keep install check aligned with the new version
              installCheckPhase = ''
                $out/bin/flux --version | grep ${version} > /dev/null
              '';

              meta = old.meta // {
                changelog = "https://github.com/fluxcd/flux2/releases/tag/v${version}";
              };
            });
          }
        );
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ fluxOverlay ];
        };
      in
      {
        devShells = {
          default = pkgs.mkShell {
            buildInputs = [
              pkgs.nix
              pkgs.colmena
              pkgs.shellcheck
              agenix.packages.${system}.default
              pkgs.kubernetes-helm
              pkgs.helmfile
              pkgs.fluxcd
              pkgs.kustomize
              pkgs.kubectl
            ];
          };
        };
      }
    );
}
