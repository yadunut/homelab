{ secretLib, kubeLib, ... }:
{
  flake.modules.nixos.kubernetes-common =
    { pkgs, config, ... }:
    let
      clusterName = config.nut.kubernetes.instanceName;
      secrets = config.age.secrets;
      mkKubeconfig = args: kubeLib.mkKubeconfig ({ inherit pkgs clusterName; } // args);
      mkDir = kubeLib.mkTmpfileDir;
      mkLinks = kubeLib.mkTmpfileLinks;
      link = dest: src: { inherit dest src; };
    in
    {
      age.secrets = builtins.mapAttrs (secretLib.mkGenerated config) {
        # Admin kubeconfig for kubectl (shared across all nodes for convenience)
        kubernetes-admin-kubeconfig = mkKubeconfig {
          name = "admin";
          user = "kubernetes-admin";
          certGenerator = "kubernetes-admin-crt";
          certFile = "admin.crt";
          keyFile = "admin.key";
          server = config.nut.kubernetes.apiServer.adminEndpoint;
          share = true;
        };
      };

      # Symlink admin kubeconfig to standard locations for kubectl
      systemd.tmpfiles.rules = [
        (mkDir { path = "/root/.kube"; })
        (mkDir {
          path = "/home/yadunut/.kube";
          user = "yadunut";
          group = "users";
        })
      ]
      ++ mkLinks [
        (link "/root/.kube/config" secrets.kubernetes-admin-kubeconfig.path)
        (link "/home/yadunut/.kube/config" secrets.kubernetes-admin-kubeconfig.path)
      ];
    };
}
