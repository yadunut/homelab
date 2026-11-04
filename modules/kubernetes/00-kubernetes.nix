{
  config,
  ...
}:
let
  nixosModules = config.flake.modules.nixos;
  clusterInputs = config.homelab.kubernetes;

  # Randomly generated RFC 4193 ULA. Keep this distinct from Tailscale's
  # fd7a:115c:a1e0::/48 address range.
  coreNetworkPrefix = "fd5f:97ba:c64d";

  kubernetesCluster =
    { config, lib, ... }:
    let
      coreNodes = config.nut.kubernetes.coreNetwork.nodes;
      controlPlaneYggdrasilAddress = clusterInputs.adminAddress;
    in
    {
      nut.kubernetes = {
        instanceName = "nut-cluster";
        nodeIP = coreNodes.${config.networking.hostName}.nodeIp;
        apiServer = {
          adminEndpoint = "https://[${controlPlaneYggdrasilAddress}]:6443";
          certSans = [ controlPlaneYggdrasilAddress ];
          oidc = {
            enable = true;
            issuerURL = "https://idm.yadunut.dev/oauth2/openid/headlamp";
            clientID = "headlamp";
            usernameClaim = "preferred_username";
            usernamePrefix = "oidc:";
            groupsClaim = "groups";
            groupsPrefix = "oidc:";
            signingAlgorithms = [ "ES256" ];
          };
        };

        controlPlane = {
          name = "nut-gc1";
          ip = coreNodes.nut-gc1.nodeIp;
        };

        coreNetwork = {
          cidr = "${coreNetworkPrefix}::/48";
          nodes = {
            nut-gc1 = {
              nodeIp = "${coreNetworkPrefix}::1";
              publicIp = clusterInputs.publicAddresses.nut-gc1;
            };
            nut-gc2 = {
              nodeIp = "${coreNetworkPrefix}::2";
              publicIp = clusterInputs.publicAddresses.nut-gc2;
            };
            penguin = {
              nodeIp = "${coreNetworkPrefix}::3";
              publicIp = clusterInputs.publicAddresses.penguin;
            };
          };
          links = {
            nut-gc1-nut-gc2 = {
              port = 51831;
              a.node = "nut-gc1";
              b.node = "nut-gc2";
            };
            nut-gc1-penguin = {
              port = 443;
              a.node = "nut-gc1";
              a.endpointIp = "167.253.159.47";
              b.node = "penguin";
            };
            nut-gc2-penguin = {
              port = 8443;
              a.node = "nut-gc2";
              a.endpointIp = "103.149.46.7";
              b.node = "penguin";
            };
          };
        };

        nodes = lib.mapAttrs (_name: node: { ip = node.nodeIp; }) coreNodes;
      };
    };
in
{
  flake.modules.nixos.kubernetes-compute =
    {
      lib,
      ...
    }:
    {
      options.nut.kubernetes.nvidia = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable NVIDIA GPU support on this Kubernetes compute node.";
        };
      };
    };
  flake.modules.nixos.kubernetes-control-plane =
    { ... }:
    {
      users.users.kubernetes.extraGroups = [ "etcd" ];
    };
  flake.modules.nixos.kubernetes-common =
    {
      config,
      lib,
      ...
    }:
    let
      # Build /etc/hosts entries so nodes can resolve each other by hostname
      # This is required for API server to proxy requests (like kubectl logs) to nodes
      kubeHosts = lib.optionalAttrs (config.nut.kubernetes.nodes != { }) (
        lib.mapAttrs' (
          machineName: node: lib.nameValuePair node.ip [ machineName ]
        ) config.nut.kubernetes.nodes
      );

      machineOptions =
        { lib, ... }:
        {
          options.ip = lib.mkOption {
            type = lib.types.str;
            description = "Kubernetes node address used for peer traffic.";
          };
        };
    in
    {
      options.nut.kubernetes = {
        instanceName = lib.mkOption {
          type = lib.types.str;
          default = "kubernetes";
          description = "Kubernetes cluster instance name (used for service identification).";
        };
        nodeIP = lib.mkOption {
          type = lib.types.str;
          description = "IPv6 address of this node for Kubernetes peer traffic.";
        };
        clusterCIDR = lib.mkOption {
          type = lib.types.str;
          description = "CIDR range for pod IPs.";
          default = "fd00:10:96::/48";
        };
        serviceCIDR = lib.mkOption {
          type = lib.types.str;
          description = "CIDR range for service IPs.";
          default = "fd00:10:97::/108";
        };
        domain = lib.mkOption {
          type = lib.types.str;
          description = "Domain suffix to use for hostname aliases";
          default = "k8s.internal";
        };
        controlPlane = {
          name = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Kubernetes control-plane node hostname.";
          };
          ip = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Kubernetes control-plane node address.";
          };
        };
        apiServer = {
          adminEndpoint = lib.mkOption {
            type = lib.types.str;
            default = "https://127.0.0.1:6443";
            description = "Kubernetes API endpoint written into the shared admin kubeconfig.";
          };
          certSans = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Additional SANs for the Kubernetes API server certificate.";
          };
          oidc = {
            enable = lib.mkEnableOption "OIDC authentication for the Kubernetes API server";
            issuerURL = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "OIDC issuer URL trusted by the Kubernetes API server.";
            };
            clientID = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "OIDC client ID accepted by the Kubernetes API server.";
            };
            usernameClaim = lib.mkOption {
              type = lib.types.str;
              default = "sub";
              description = "OIDC claim used as the Kubernetes username.";
            };
            usernamePrefix = lib.mkOption {
              type = lib.types.str;
              default = "oidc:";
              description = "Prefix added to usernames authenticated through OIDC.";
            };
            groupsClaim = lib.mkOption {
              type = lib.types.str;
              default = "groups";
              description = "OIDC claim containing Kubernetes group memberships.";
            };
            groupsPrefix = lib.mkOption {
              type = lib.types.str;
              default = "oidc:";
              description = "Prefix added to groups authenticated through OIDC.";
            };
            signingAlgorithms = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "RS256" ];
              description = "JWT signing algorithms accepted from the OIDC issuer.";
            };
          };
        };
        nodes = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule machineOptions);
          default = { };
          description = "All Kubernetes nodes keyed by hostname.";
        };
        etcd = {
          endpoints = lib.mkOption {
            type = lib.types.str;
            description = "Comma-separated list of etcd endpoints for kube-apiserver.";
            default = "";
          };
          initialCluster = lib.mkOption {
            type = lib.types.str;
            description = "Initial cluster configuration for etcd.";
            default = "";
          };
        };
      };
      config = {
        assertions = [
          {
            assertion =
              !config.nut.kubernetes.apiServer.oidc.enable
              || config.nut.kubernetes.apiServer.oidc.issuerURL != "";
            message = "nut.kubernetes.apiServer.oidc.issuerURL must be set when OIDC is enabled.";
          }
          {
            assertion =
              !config.nut.kubernetes.apiServer.oidc.enable || config.nut.kubernetes.apiServer.oidc.clientID != "";
            message = "nut.kubernetes.apiServer.oidc.clientID must be set when OIDC is enabled.";
          }
          {
            assertion =
              !config.nut.kubernetes.apiServer.oidc.enable
              || config.nut.kubernetes.apiServer.oidc.signingAlgorithms != [ ];
            message = "nut.kubernetes.apiServer.oidc.signingAlgorithms must not be empty when OIDC is enabled.";
          }
        ];

        # Add /etc/hosts entries for all kubernetes nodes
        # This allows the API server to resolve node hostnames when proxying requests
        # (e.g., kubectl logs requires the API server to connect to the node's kubelet)
        networking.hosts = kubeHosts;

        users.groups.kubernetes.gid = config.ids.gids.kubernetes;
        users.users.kubernetes = {
          uid = config.ids.uids.kubernetes;
          description = "Kubernetes user";
          group = "kubernetes";
          home = "/var/lib/kubernetes";
          createHome = true;
          homeMode = "755";
        };
        users.users.yadunut.extraGroups = [ "kubernetes" ];
        systemd.targets.kubernetes = {
          description = "Kubernetes";
          wantedBy = [ "multi-user.target" ];
        };

        systemd.tmpfiles.rules = [
          # Root ownership to allow subdirectories with different owners (pki, etcd)
          "d /var/lib/kubernetes 0755 root root -"
        ];
      };
    };
  perSystem =
    { pkgs, ... }:
    {
      make-shells.default.packages = [
        pkgs.step-cli
        pkgs.openssl
      ];
    };

  configurations.nixos.nut-gc1.module = {
    imports = with nixosModules; [
      kubernetesCluster
      kubernetes-common
      kubernetes-control-plane
      kubernetes-compute
    ];
  };

  configurations.nixos.nut-gc2.module = {
    imports = with nixosModules; [
      kubernetesCluster
      kubernetes-common
      kubernetes-compute
    ];
  };

  configurations.nixos.penguin.module = {
    imports = with nixosModules; [
      kubernetesCluster
      kubernetes-common
      kubernetes-compute
    ];

    nut.kubernetes.nvidia.enable = true;
  };
}
