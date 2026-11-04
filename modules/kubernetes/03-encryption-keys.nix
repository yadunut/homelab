{
  secretLib,
  config,
  kubeLib,
  ...
}:
{
  flake.modules.nixos.kubernetes-control-plane =
    { pkgs, config, ... }:
    let
      secrets = config.age.secrets;
      mkLinks = kubeLib.mkTmpfileLinks;
      link = dest: src: { inherit dest src; };
    in
    {
      age.secrets = builtins.mapAttrs (secretLib.mkGenerated config) {
        kubernetes-encryption-config = {
          share = true;
          file = "encryption-config.yaml";
          owner = "kubernetes";
          group = "kubernetes";
          mode = "0440";

          runtimeInputs = pkgs: [
            pkgs.openssl
            pkgs.coreutils
          ];
          script = ''
            ENCRYPTION_KEY=$(openssl rand -base64 32)

            cat > $out/encryption-config.yaml <<EOF
            apiVersion: apiserver.config.k8s.io/v1
            kind: EncryptionConfiguration
            resources:
              - resources:
                  - secrets
                providers:
                  - aescbc:
                      keys:
                        - name: key1
                          secret: $ENCRYPTION_KEY
                  - identity: {}
            EOF
          '';
        };
      };

      # Symlink encryption config to standard location for kube-apiserver
      systemd.tmpfiles.rules = mkLinks [
        (link "/var/lib/kubernetes/encryption-config.yaml" secrets.kubernetes-encryption-config.path)
      ];
    };
}
