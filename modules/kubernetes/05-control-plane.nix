{ secretLib, kubeLib, ... }:
{
  flake.modules.nixos.kubernetes-control-plane =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      secrets = config.age.secrets;
      clusterName = config.nut.kubernetes.instanceName;
      clusterCIDR = config.nut.kubernetes.clusterCIDR;
      clusterDomain = config.nut.kubernetes.domain;
      serviceCIDR = config.nut.kubernetes.serviceCIDR;
      nodeIP = config.nut.kubernetes.nodeIP;
      etcdEndpoints = config.nut.kubernetes.etcd.endpoints;
      oidc = config.nut.kubernetes.apiServer.oidc;
      oidcCommandArgs = lib.optionalString oidc.enable (
        lib.concatMapStrings (argument: "${lib.escapeShellArg argument} \\\n              ") [
          "--oidc-issuer-url=${oidc.issuerURL}"
          "--oidc-client-id=${oidc.clientID}"
          "--oidc-username-claim=${oidc.usernameClaim}"
          "--oidc-username-prefix=${oidc.usernamePrefix}"
          "--oidc-groups-claim=${oidc.groupsClaim}"
          "--oidc-groups-prefix=${oidc.groupsPrefix}"
          "--oidc-signing-algs=${lib.concatStringsSep "," oidc.signingAlgorithms}"
        ]
      );
      mkKubeconfig = args: kubeLib.mkKubeconfig ({ inherit pkgs clusterName; } // args);
      mkLinks = kubeLib.mkTmpfileLinks;
      link = dest: src: { inherit dest src; };
    in
    {
      environment.systemPackages = [ pkgs.kubernetes ];

      # Generate kubeconfig files for scheduler and controller-manager
      age.secrets = builtins.mapAttrs (secretLib.mkGenerated config) {
        kubernetes-scheduler-kubeconfig = mkKubeconfig {
          name = "kube-scheduler";
          user = "system:kube-scheduler";
          certGenerator = "kubernetes-scheduler-crt";
          certFile = "scheduler.crt";
          keyFile = "scheduler.key";
          server = "https://[${nodeIP}]:6443";
        };

        kubernetes-controller-manager-kubeconfig = mkKubeconfig {
          name = "kube-controller-manager";
          user = "system:kube-controller-manager";
          certGenerator = "kubernetes-controller-manager-crt";
          certFile = "controller-manager.crt";
          keyFile = "controller-manager.key";
          server = "https://[${nodeIP}]:6443";
        };
      };

      # Symlink kubeconfig files to standard location
      systemd.tmpfiles.rules = mkLinks [
        (link "/var/lib/kubernetes/kube-scheduler.kubeconfig" secrets.kubernetes-scheduler-kubeconfig.path)
        (link "/var/lib/kubernetes/kube-controller-manager.kubeconfig" secrets.kubernetes-controller-manager-kubeconfig.path)
      ];

      systemd.services."kube-apiserver" = {
        description = "Kubernetes API Server";
        documentation = [ "https://github.com/kubernetes/kubernetes" ];
        wantedBy = [ "kubernetes.target" ];
        after = [
          "network.target"
          "kubernetes-core-network-ready.service"
          "etcd.service"
          "systemd-tmpfiles-setup.service"
        ];
        wants = [ "kubernetes-core-network-ready.service" ];
        requires = [
          "kubernetes-core-network-ready.service"
          "etcd.service"
        ];

        serviceConfig = {
          ExecStartPre = [
            # Wait for the node IP to be available on some interface
            (kubeLib.mkWaitForIP {
              inherit pkgs;
              nodeIP = nodeIP;
            })
          ];
          ExecStart = ''
            ${pkgs.kubernetes}/bin/kube-apiserver \
              --allow-privileged=true \
              --audit-log-path=- \
              --authorization-mode=Node,RBAC \
              --bind-address=:: \
              --advertise-address=${nodeIP} \
              --client-ca-file=/var/lib/kubernetes/pki/ca.crt \
              --enable-admission-plugins=NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota,DefaultTolerationSeconds \
              --etcd-servers=${etcdEndpoints} \
              --etcd-cafile=/var/lib/kubernetes/pki/etcd/ca.crt \
              --etcd-certfile=/var/lib/kubernetes/pki/apiserver-etcd-client.crt \
              --etcd-keyfile=/var/lib/kubernetes/pki/apiserver-etcd-client.key \
              --event-ttl=1h \
              --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \
              --kubelet-certificate-authority=/var/lib/kubernetes/pki/ca.crt \
              --kubelet-client-certificate=/var/lib/kubernetes/pki/apiserver-kubelet-client.crt \
              --kubelet-client-key=/var/lib/kubernetes/pki/apiserver-kubelet-client.key \
              ${oidcCommandArgs}--runtime-config=api/all=true \
              --service-account-key-file=/var/lib/kubernetes/pki/sa.pub \
              --service-account-signing-key-file=/var/lib/kubernetes/pki/sa.key \
              --service-account-issuer=https://kubernetes.default.svc.${clusterDomain} \
              --service-cluster-ip-range=${serviceCIDR} \
              --service-node-port-range=30000-32767 \
              --tls-cert-file=/var/lib/kubernetes/pki/apiserver.crt \
              --tls-private-key-file=/var/lib/kubernetes/pki/apiserver.key \
              --requestheader-client-ca-file=/var/lib/kubernetes/pki/front-proxy-ca.crt \
              --requestheader-allowed-names=front-proxy-client \
              --requestheader-extra-headers-prefix=X-Remote-Extra- \
              --requestheader-group-headers=X-Remote-Group \
              --requestheader-username-headers=X-Remote-User \
              --proxy-client-cert-file=/var/lib/kubernetes/pki/front-proxy-client.crt \
              --proxy-client-key-file=/var/lib/kubernetes/pki/front-proxy-client.key \
              --enable-aggregator-routing=true \
              --v=2
          '';
          Restart = "on-failure";
          RestartSec = 5;
          User = "kubernetes";
          Group = "kubernetes";
        };
      };

      environment.etc."kubernetes/config/kube-scheduler.yaml".text = ''
        apiVersion: kubescheduler.config.k8s.io/v1
        kind: KubeSchedulerConfiguration
        clientConnection:
          kubeconfig: "/var/lib/kubernetes/kube-scheduler.kubeconfig"
        leaderElection:
          leaderElect: true
      '';

      systemd.services."kube-scheduler" = {
        description = "Kubernetes Scheduler";
        documentation = [ "https://github.com/kubernetes/kubernetes" ];
        wantedBy = [ "kubernetes.target" ];
        after = [
          "kube-apiserver.service"
          "systemd-tmpfiles-setup.service"
        ];
        bindsTo = [ "kube-apiserver.service" ];

        serviceConfig = {
          ExecStart = ''
            ${pkgs.kubernetes}/bin/kube-scheduler \
              --config=/etc/kubernetes/config/kube-scheduler.yaml \
              --v=2
          '';
          Restart = "on-failure";
          RestartSec = 5;
          User = "kubernetes";
          Group = "kubernetes";
        };
      };

      systemd.services."kube-controller-manager" = {
        description = "Kubernetes Controller Manager";
        documentation = [ "https://github.com/kubernetes/kubernetes" ];
        wantedBy = [ "kubernetes.target" ];
        after = [
          "kube-apiserver.service"
          "systemd-tmpfiles-setup.service"
        ];
        bindsTo = [ "kube-apiserver.service" ];

        serviceConfig = {
          ExecStart = ''
            ${pkgs.kubernetes}/bin/kube-controller-manager \
              --allocate-node-cidrs=true \
              --bind-address=:: \
              --cluster-cidr=${clusterCIDR} \
              --cluster-name=${clusterName} \
              --cluster-signing-cert-file=/var/lib/kubernetes/pki/ca.crt \
              --cluster-signing-key-file=/var/lib/kubernetes/pki/ca.key \
              --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \
              --root-ca-file=/var/lib/kubernetes/pki/ca.crt \
              --service-account-private-key-file=/var/lib/kubernetes/pki/sa.key \
              --service-cluster-ip-range=${serviceCIDR} \
              --use-service-account-credentials=true \
              --v=2
          '';
          Restart = "on-failure";
          RestartSec = 5;
          User = "kubernetes";
          Group = "kubernetes";
        };
      };
    };
}
