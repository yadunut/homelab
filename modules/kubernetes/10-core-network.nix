{ config, secretLib, ... }:
let
  publicKeys = config.homelab.kubernetes.wireguardPublicKeys;
in
{
  flake.modules.nixos.kubernetes-common =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.nut.kubernetes.coreNetwork;
      hostName = config.networking.hostName;
      isCoreNode = builtins.hasAttr hostName cfg.nodes;
      localNode = cfg.nodes.${hostName};
      localGeneratorName = "kubernetes-core-wireguard-${hostName}";
      localPrivateKeyFile = config.age.secrets.${localGeneratorName}.path;

      publicKeyFor = node: publicKeys.${node};

      linkHasNode = link: link.a.node == hostName || link.b.node == hostName;
      peerSide = link: if link.a.node == hostName then link.b else link.a;
      localLinkLocalAddress = link: if link.a.node == hostName then "fe80::1/64" else "fe80::2/64";
      localLinks = lib.filterAttrs (_name: link: linkHasNode link) cfg.links;
      localLinkPorts = lib.unique (lib.mapAttrsToList (_name: link: link.port) localLinks);
      localLinkPortSet = "{ ${lib.concatMapStringsSep ", " toString localLinkPorts} }";
      remoteLoopbackCidrs = lib.mapAttrsToList (_name: node: "${node.nodeIp}/128") (
        lib.filterAttrs (name: _node: name != hostName) cfg.nodes
      );
      podTrafficCidrs = [ config.nut.kubernetes.clusterCIDR ];
      babelControlCidrs = [
        "fe80::/64"
        "ff02::1:6/128"
      ];

      mkWireGuardInterface =
        name: link:
        let
          peer = peerSide link;
          peerNode = cfg.nodes.${peer.node};
          peerEndpointIp = if peer.endpointIp != null then peer.endpointIp else peerNode.publicIp;
          peerEndpoint =
            if peerEndpointIp == null then
              null
            else if lib.hasInfix ":" peerEndpointIp then
              "[${peerEndpointIp}]"
            else
              peerEndpointIp;
          peerPublicKey = publicKeyFor peer.node;
        in
        lib.nameValuePair name {
          ips = [ (localLinkLocalAddress link) ];
          listenPort = link.port;
          privateKeyFile = localPrivateKeyFile;
          allowedIPsAsRoutes = false;
          peers = lib.optionals (peerPublicKey != null) [
            (
              {
                publicKey = peerPublicKey;
                allowedIPs = lib.unique (remoteLoopbackCidrs ++ podTrafficCidrs ++ babelControlCidrs);
              }
              // lib.optionalAttrs (peerEndpoint != null) {
                endpoint = "${peerEndpoint}:${toString link.port}";
              }
              // lib.optionalAttrs (localNode.publicIp == null && peerEndpointIp != null) {
                persistentKeepalive = 25;
              }
            )
          ];
        };

      coreNodeOptions =
        { ... }:
        {
          options = {
            nodeIp = lib.mkOption {
              type = lib.types.str;
              description = "Stable Kubernetes core node address.";
            };
            publicIp = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Public IPv6 address used by WireGuard peers. Null means the node endpoint is learned from incoming WireGuard traffic.";
            };
          };
        };

      linkSideOptions =
        { ... }:
        {
          options = {
            node = lib.mkOption {
              type = lib.types.str;
              description = "Node name for this side of the link.";
            };
            endpointIp = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional endpoint address override for peers dialing this side of the link.";
            };
          };
        };

      linkOptions =
        { ... }:
        {
          options = {
            port = lib.mkOption {
              type = lib.types.port;
              description = "WireGuard UDP listen port for this link.";
            };
            a = lib.mkOption {
              type = lib.types.submodule linkSideOptions;
              description = "First side of the point-to-point link.";
            };
            b = lib.mkOption {
              type = lib.types.submodule linkSideOptions;
              description = "Second side of the point-to-point link.";
            };
          };
        };
    in
    {
      options.nut.kubernetes.coreNetwork = {
        cidr = lib.mkOption {
          type = lib.types.str;
          description = "Kubernetes WireGuard core network CIDR.";
        };
        nodes = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule coreNodeOptions);
          description = "Kubernetes core network nodes keyed by hostname.";
        };
        links = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule linkOptions);
          description = "Point-to-point Kubernetes core WireGuard links.";
        };
      };

      config = lib.mkIf isCoreNode {
        assertions = lib.mapAttrsToList (name: link: {
          assertion = cfg.nodes.${link.a.node}.publicIp != null || cfg.nodes.${link.b.node}.publicIp != null;
          message = "Kubernetes core network link ${name} must have at least one node with a publicIp.";
        }) cfg.links;

        age.secrets.${localGeneratorName} = secretLib.mkGenerated config localGeneratorName {
          file = "privatekey";
          publicFiles = [ "publickey" ];
          owner = "systemd-network";
          group = "systemd-network";
          mode = "0440";
          share = false;
          runtimeInputs = pkgs: [ pkgs.wireguard-tools ];
          script = ''
            umask 077
            wg genkey > $out/privatekey
            wg pubkey < $out/privatekey > $out/publickey
          '';
        };

        networking.firewall = {
          allowedUDPPorts = lib.mapAttrsToList (_name: link: link.port) localLinks;
          trustedInterfaces = lib.attrNames localLinks;
        };

        networking.wireguard.interfaces = lib.mapAttrs' mkWireGuardInterface localLinks;

        networking.nftables.tables.kubernetes-core-wireguard-dscp = {
          family = "inet";
          content = ''
            chain output {
              type route hook output priority mangle; policy accept;
              meta l4proto udp udp sport ${localLinkPortSet} udp dport ${localLinkPortSet} ip6 dscp set cs0 meta priority set 0
            }

            chain postrouting {
              type filter hook postrouting priority mangle; policy accept;
              meta l4proto udp udp sport ${localLinkPortSet} udp dport ${localLinkPortSet} ip6 dscp set cs0 meta priority set 0
            }
          '';
        };
      };
    };
}
