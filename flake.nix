{
  description = "Homelab Kubernetes host modules and Flux configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      flake.flakeModules.kubernetes = ./modules/kubernetes.nix;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem = { pkgs, ... }: {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.fluxcd
            pkgs.kubectl
            pkgs.cilium-cli
            pkgs.kubernetes-helm
            pkgs.kanidm_1_11
            pkgs.deno
          ];
        };
      };
    };
}
