{ secretLib, kubeLib, ... }:
{
  flake.modules.nixos.kubernetes-common =
    { pkgs, config, ... }:
    {
      age.secrets = builtins.mapAttrs (secretLib.mkGenerated config) {
        # Kubernetes CA (signs all Kubernetes component certificates)
        kubernetes-ca-crt = {
          share = true;
          file = "ca.key";
          publicFiles = [ "ca.crt" ];
          owner = "kubernetes";
          group = "kubernetes";
          mode = "0440";

          runtimeInputs = pkgs: [ pkgs.step-cli ];
          script = ''
            step certificate create "kubernetes-ca" $out/ca.crt $out/ca.key \
            --profile root-ca \
            --no-password --insecure --not-after 87600h
          '';
        };
        # etcd CA (signs all etcd-related certificates)
        etcd-ca-crt = {
          share = true;
          file = "ca.key";
          publicFiles = [ "ca.crt" ];
          owner = "root";
          group = "root";
          mode = "0440";

          runtimeInputs = pkgs: [ pkgs.step-cli ];
          script = ''
            step certificate create "etcd-ca" $out/ca.crt $out/ca.key \
            --profile root-ca \
            --no-password --insecure --not-after 87600h
          '';
        };
        # Front Proxy CA (for API aggregation layer - required by metrics-server, etc.)
        kubernetes-front-proxy-ca-crt = {
          share = true;
          file = "front-proxy-ca.key";
          publicFiles = [ "front-proxy-ca.crt" ];
          owner = "kubernetes";
          group = "kubernetes";
          mode = "0440";

          runtimeInputs = pkgs: [ pkgs.step-cli ];
          script = ''
            step certificate create "kubernetes-front-proxy-ca" $out/front-proxy-ca.crt $out/front-proxy-ca.key \
            --profile root-ca \
            --no-password --insecure --not-after 87600h
          '';
        };
        # Front Proxy Client certificate (used by API server for aggregation)
        kubernetes-front-proxy-client-crt = {
          share = true;
          file = "front-proxy-client.key";
          publicFiles = [ "front-proxy-client.crt" ];
          owner = "kubernetes";
          group = "kubernetes";
          mode = "0440";

          dependencies = [ "kubernetes-front-proxy-ca-crt" ];
          runtimeInputs = pkgs: [ pkgs.step-cli ];
          script = ''
            cat > front-proxy-client.tpl <<EOF
            {
              "subject": {
                "commonName": "front-proxy-client"
              },
              "keyUsage": ["digitalSignature", "keyEncipherment"],
              "basicConstraints": { "isCA": false },
              "extKeyUsage": ["clientAuth"]
            }
            EOF

            step certificate create front-proxy-client $out/front-proxy-client.crt $out/front-proxy-client.key \
            --template front-proxy-client.tpl \
            --ca $in/kubernetes-front-proxy-ca-crt/front-proxy-ca.crt \
            --ca-key $in/kubernetes-front-proxy-ca-crt/front-proxy-ca.key \
            --no-password --insecure \
            --not-after 8760h
          '';
        };
        # Admin certificate for kubectl
        kubernetes-admin-crt = {
          share = true;
          file = "admin.key";
          publicFiles = [ "admin.crt" ];
          owner = "root";
          group = "root";
          mode = "0440";

          dependencies = [ "kubernetes-ca-crt" ];
          runtimeInputs = pkgs: [ pkgs.step-cli ];
          script = ''
            cat > admin.tpl <<EOF
            {
              "subject": {
                "commonName": "kubernetes-admin",
                "organization": ["system:masters"]
              },
              "keyUsage": ["digitalSignature", "keyEncipherment"],
              "basicConstraints": { "isCA": false },
              "extKeyUsage": ["clientAuth"]
            }
            EOF

            step certificate create admin $out/admin.crt $out/admin.key \
            --template admin.tpl \
            --ca $in/kubernetes-ca-crt/ca.crt \
            --ca-key $in/kubernetes-ca-crt/ca.key \
            --no-password --insecure \
            --not-after 8760h
          '';
        };
      };
    };

  flake.modules.nixos.kubernetes-control-plane =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      hostname = config.networking.hostName;
      nodeIp = config.nut.kubernetes.nodeIP;
      serviceCIDR = config.nut.kubernetes.serviceCIDR;
      clusterDomain = config.nut.kubernetes.domain;
      secrets = config.age.secrets;

      # Calculate first service IP from service CIDR (for kubernetes.default ClusterIP)
      kubernetesServiceIP = kubeLib.firstServiceIP serviceCIDR;

      mkK8sCertificate = args: kubeLib.mkK8sCertificate ({ inherit pkgs; } // args);
      mkEtcdCertificate = args: kubeLib.mkEtcdCertificate ({ inherit pkgs; } // args);

      mkDir = kubeLib.mkTmpfileDir;
      mkLinks = kubeLib.mkTmpfileLinks;
      link = dest: src: { inherit dest src; };
    in
    {
      age.secrets = builtins.mapAttrs (secretLib.mkGenerated config) {

        # Service account key pair (not a certificate)
        kubernetes-service-account-keys = {
          share = true;
          file = "sa.key";
          publicFiles = [ "sa.pub" ];
          owner = "kubernetes";
          group = "kubernetes";
          mode = "0440";

          runtimeInputs = pkgs: [ pkgs.openssl ];
          script = ''
            # Generate ECDSA P-256 private key
            openssl ecparam -genkey -name prime256v1 -noout -out sa.key
            # Extract public key from private key
            openssl ec -in sa.key -pubout -out sa.pub
            mv sa.key $out/sa.key
            mv sa.pub $out/sa.pub
          '';
        };

        # Kubernetes API Server certificate
        # SANs include the control-plane IP plus the kubernetes service ClusterIP.
        kubernetes-apiserver-crt = mkK8sCertificate {
          name = "apiserver";
          commonName = "kube-apiserver";
          extKeyUsage = [
            "serverAuth"
            "clientAuth"
          ];
          keyOwner = "kubernetes";
          keyGroup = "kubernetes";
          sans = lib.unique (
            lib.filter (san: san != null) [
              "127.0.0.1"
              "::1"
              "localhost"
              "kubernetes"
              "kubernetes.default"
              "kubernetes.default.svc"
              "kubernetes.default.svc.${clusterDomain}"
              hostname
              nodeIp
              config.nut.kubernetes.controlPlane.ip
              kubernetesServiceIP # First service IP for kubernetes.default ClusterIP
            ]
            ++ config.nut.kubernetes.apiServer.certSans
          );
        };

        # API Server etcd client certificate (signed by etcd CA)
        kubernetes-apiserver-etcd-client-crt = mkEtcdCertificate {
          name = "apiserver-etcd-client";
          commonName = "kube-apiserver-etcd-client";
          extKeyUsage = [ "clientAuth" ];
          keyOwner = "kubernetes";
          keyGroup = "kubernetes";
        };

        # API Server kubelet client certificate
        kubernetes-apiserver-kubelet-client-crt = mkK8sCertificate {
          name = "apiserver-kubelet-client";
          commonName = "kube-apiserver-kubelet-client";
          extKeyUsage = [ "clientAuth" ];
        };

        # Controller Manager certificate
        kubernetes-controller-manager-crt = mkK8sCertificate {
          name = "controller-manager";
          commonName = "system:kube-controller-manager";
          orgs = [ "system:kube-controller-manager" ];
          extKeyUsage = [ "clientAuth" ];
        };

        # Scheduler certificate
        kubernetes-scheduler-crt = mkK8sCertificate {
          name = "scheduler";
          commonName = "system:kube-scheduler";
          orgs = [ "system:kube-scheduler" ];
          extKeyUsage = [ "clientAuth" ];
        };

        # etcd server certificate (per control-plane node)
        etcd-server-crt = mkEtcdCertificate {
          name = "etcd-server";
          commonName = "kube-etcd";
          extKeyUsage = [
            "serverAuth"
            "clientAuth"
          ];
          sans = [
            hostname
            "127.0.0.1"
            "::1"
            "localhost"
            nodeIp
          ];
        };

        # etcd peer certificate (per control-plane node)
        etcd-peer-crt = mkEtcdCertificate {
          name = "etcd-peer";
          commonName = "kube-etcd-peer";
          extKeyUsage = [
            "serverAuth"
            "clientAuth"
          ];
          sans = [
            hostname
            "127.0.0.1"
            "::1"
            "localhost"
            nodeIp
          ];
        };

        # etcd healthcheck client certificate (shared)
        etcd-healthcheck-client-crt = mkEtcdCertificate {
          name = "etcd-healthcheck-client";
          commonName = "kube-etcd-healthcheck-client";
          extKeyUsage = [ "clientAuth" ];
          share = true;
        };

        # Kubelet server certificate (per node)
        kubernetes-kubelet-server-crt = mkK8sCertificate {
          name = "kubelet-server";
          commonName = "system:node:${hostname}";
          orgs = [ "system:nodes" ];
          extKeyUsage = [ "serverAuth" ];
          sans = [
            hostname
            "127.0.0.1"
            "::1"
            "localhost"
            nodeIp
          ];
        };

        # Kubelet client certificate (per node)
        kubernetes-kubelet-client-crt = mkK8sCertificate {
          name = "kubelet-client";
          commonName = "system:node:${hostname}";
          orgs = [ "system:nodes" ];
          extKeyUsage = [ "clientAuth" ];
        };
      };

      systemd.tmpfiles.rules =
        let
          pkiLinks = [
            # Kubernetes CA
            (link "/var/lib/kubernetes/pki/ca.crt" secrets.kubernetes-ca-crt.settings.publicFiles."ca.crt")
            (link "/var/lib/kubernetes/pki/ca.key" secrets.kubernetes-ca-crt.path)

            # API Server certificates
            (link "/var/lib/kubernetes/pki/apiserver.crt"
              secrets.kubernetes-apiserver-crt.settings.publicFiles."apiserver.crt"
            )
            (link "/var/lib/kubernetes/pki/apiserver.key" secrets.kubernetes-apiserver-crt.path)
            (link "/var/lib/kubernetes/pki/apiserver-etcd-client.crt"
              secrets.kubernetes-apiserver-etcd-client-crt.settings.publicFiles."apiserver-etcd-client.crt"
            )
            (link "/var/lib/kubernetes/pki/apiserver-etcd-client.key" secrets.kubernetes-apiserver-etcd-client-crt.path)
            (link "/var/lib/kubernetes/pki/apiserver-kubelet-client.crt"
              secrets.kubernetes-apiserver-kubelet-client-crt.settings.publicFiles."apiserver-kubelet-client.crt"
            )
            (link "/var/lib/kubernetes/pki/apiserver-kubelet-client.key" secrets.kubernetes-apiserver-kubelet-client-crt.path)

            # Controller Manager certificate
            (link "/var/lib/kubernetes/pki/controller-manager.crt"
              secrets.kubernetes-controller-manager-crt.settings.publicFiles."controller-manager.crt"
            )
            (link "/var/lib/kubernetes/pki/controller-manager.key" secrets.kubernetes-controller-manager-crt.path)

            # Scheduler certificate
            (link "/var/lib/kubernetes/pki/scheduler.crt"
              secrets.kubernetes-scheduler-crt.settings.publicFiles."scheduler.crt"
            )
            (link "/var/lib/kubernetes/pki/scheduler.key" secrets.kubernetes-scheduler-crt.path)

            # Service account keys
            (link "/var/lib/kubernetes/pki/sa.key" secrets.kubernetes-service-account-keys.path)
            (link "/var/lib/kubernetes/pki/sa.pub"
              secrets.kubernetes-service-account-keys.settings.publicFiles."sa.pub"
            )
          ];

          etcdLinks = [
            # etcd CA
            (link "/var/lib/kubernetes/pki/etcd/ca.crt" secrets.etcd-ca-crt.settings.publicFiles."ca.crt")
            (link "/var/lib/kubernetes/pki/etcd/ca.key" secrets.etcd-ca-crt.path)

            # etcd certificates
            (link "/var/lib/kubernetes/pki/etcd/server.crt"
              secrets.etcd-server-crt.settings.publicFiles."etcd-server.crt"
            )
            (link "/var/lib/kubernetes/pki/etcd/server.key" secrets.etcd-server-crt.path)
            (link "/var/lib/kubernetes/pki/etcd/peer.crt"
              secrets.etcd-peer-crt.settings.publicFiles."etcd-peer.crt"
            )
            (link "/var/lib/kubernetes/pki/etcd/peer.key" secrets.etcd-peer-crt.path)
            (link "/var/lib/kubernetes/pki/etcd/healthcheck-client.crt"
              secrets.etcd-healthcheck-client-crt.settings.publicFiles."etcd-healthcheck-client.crt"
            )
            (link "/var/lib/kubernetes/pki/etcd/healthcheck-client.key" secrets.etcd-healthcheck-client-crt.path)
          ];

          frontProxyLinks = [
            # Front Proxy certificates (for API aggregation layer)
            (link "/var/lib/kubernetes/pki/front-proxy-ca.crt"
              secrets.kubernetes-front-proxy-ca-crt.settings.publicFiles."front-proxy-ca.crt"
            )
            (link "/var/lib/kubernetes/pki/front-proxy-ca.key" secrets.kubernetes-front-proxy-ca-crt.path)
            (link "/var/lib/kubernetes/pki/front-proxy-client.crt"
              secrets.kubernetes-front-proxy-client-crt.settings.publicFiles."front-proxy-client.crt"
            )
            (link "/var/lib/kubernetes/pki/front-proxy-client.key" secrets.kubernetes-front-proxy-client-crt.path)
          ];

          kubeletLinks = [
            # Kubelet certificates (for control-plane nodes that also run kubelet)
            (link "/var/lib/kubelet/ca.crt" secrets.kubernetes-ca-crt.settings.publicFiles."ca.crt")
            (link "/var/lib/kubelet/kubelet-server.crt"
              secrets.kubernetes-kubelet-server-crt.settings.publicFiles."kubelet-server.crt"
            )
            (link "/var/lib/kubelet/kubelet-server.key" secrets.kubernetes-kubelet-server-crt.path)
            (link "/var/lib/kubelet/kubelet-client.crt"
              secrets.kubernetes-kubelet-client-crt.settings.publicFiles."kubelet-client.crt"
            )
            (link "/var/lib/kubelet/kubelet-client.key" secrets.kubernetes-kubelet-client-crt.path)
          ];
        in
        [
          (mkDir { path = "/var/lib/kubernetes/pki"; })
          (mkDir {
            path = "/var/lib/kubernetes/pki/etcd";
            user = "etcd";
            group = "etcd";
          })
          (mkDir {
            path = "/var/lib/etcd";
            user = "etcd";
            group = "etcd";
          })
          (mkDir { path = "/var/lib/kubelet"; })
        ]
        ++ mkLinks (pkiLinks ++ etcdLinks ++ frontProxyLinks ++ kubeletLinks);
    };

  flake.modules.nixos.kubernetes-compute =
    { pkgs, config, ... }:
    let
      hostname = config.networking.hostName;
      nodeIp = config.nut.kubernetes.nodeIP;
      secrets = config.age.secrets;

      mkK8sCertificate = args: kubeLib.mkK8sCertificate ({ inherit pkgs; } // args);
      mkDir = kubeLib.mkTmpfileDir;
      mkLinks = kubeLib.mkTmpfileLinks;
      link = dest: src: { inherit dest src; };
    in
    {
      age.secrets = builtins.mapAttrs (secretLib.mkGenerated config) {
        # Kubelet server certificate (per node)
        kubernetes-kubelet-server-crt = mkK8sCertificate {
          name = "kubelet-server";
          commonName = "system:node:${hostname}";
          orgs = [ "system:nodes" ];
          extKeyUsage = [ "serverAuth" ];
          sans = [
            hostname
            "127.0.0.1"
            "::1"
            "localhost"
            nodeIp
          ];
        };

        # Kubelet client certificate (per node)
        kubernetes-kubelet-client-crt = mkK8sCertificate {
          name = "kubelet-client";
          commonName = "system:node:${hostname}";
          orgs = [ "system:nodes" ];
          extKeyUsage = [ "clientAuth" ];
        };
      };

      systemd.tmpfiles.rules =
        let
          links = [
            (link "/var/lib/kubelet/ca.crt" secrets.kubernetes-ca-crt.settings.publicFiles."ca.crt")
            (link "/var/lib/kubelet/kubelet-server.crt"
              secrets.kubernetes-kubelet-server-crt.settings.publicFiles."kubelet-server.crt"
            )
            (link "/var/lib/kubelet/kubelet-server.key" secrets.kubernetes-kubelet-server-crt.path)
            (link "/var/lib/kubelet/kubelet-client.crt"
              secrets.kubernetes-kubelet-client-crt.settings.publicFiles."kubelet-client.crt"
            )
            (link "/var/lib/kubelet/kubelet-client.key" secrets.kubernetes-kubelet-client-crt.path)
          ];
        in
        [
          (mkDir { path = "/var/lib/kubelet"; })
        ]
        ++ mkLinks links;
    };
}
