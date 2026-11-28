{ ... }:
{
  flake.modules.nixos.kubernetes-common =
    {
      config,
      lib,
      ...
    }:
    let
      cfg = config.nut.kubernetes.nat64;
      hostName = config.networking.hostName;
      nodeIPv4 = cfg.nodeIPv4.${hostName} or null;
      mkPool4 = protocol: {
        inherit protocol;
        prefix = "${nodeIPv4}/32";
        "port range" = cfg.portRange;
      };
    in
    {
      options.nut.kubernetes.nat64 = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable local-node Jool stateful NAT64 for IPv6-only Kubernetes pods.";
        };
        prefix = lib.mkOption {
          type = lib.types.str;
          default = "64:ff9b::/96";
          description = "NAT64 IPv6 translation prefix.";
        };
        portRange = lib.mkOption {
          type = lib.types.str;
          default = "61001-65535";
          description = "IPv4 source port/ICMP ID range reserved for Jool pool4 translations.";
        };
        nodeIPv4 = lib.mkOption {
          type = lib.types.attrsOf (lib.types.nullOr lib.types.str);
          default = {
            nut-gc1 = "167.253.159.47";
            nut-gc2 = "103.149.46.7";
            penguin = null;
          };
          description = "Primary IPv4 egress address for each node's NAT64 translator. Null uses Jool's automatic interface address selection for DHCP nodes.";
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = nodeIPv4 != null || cfg.portRange == "61001-65535";
            message = "Automatic NAT64 IPv4 address selection uses Jool's fixed port range 61001-65535.";
          }
        ];
        boot.kernel.sysctl = {
          "net.ipv4.conf.all.forwarding" = 1;
          "net.ipv4.ip_forward" = 1;
        };

        networking.jool = {
          enable = true;
          nat64.default = {
            global.pool6 = cfg.prefix;
            # An empty pool4 follows the outgoing interface's IPv4 address.
            # Jool reserves ports 61001-65535 in this mode.
            pool4 = lib.optionals (nodeIPv4 != null) (map mkPool4 [
              "TCP"
              "UDP"
              "ICMP"
            ]);
          };
        };

        # Cilium marks pod-originated packets. Jool's pool4 lookup includes the
        # packet mark, so clear marks for NAT64 destinations before Jool's
        # netfilter hook evaluates the packet.
        networking.nftables.tables.kubernetes-nat64-clear-mark = {
          family = "inet";
          content = ''
            chain prerouting {
              type filter hook prerouting priority raw; policy accept;
              ip6 daddr ${cfg.prefix} meta mark set 0
            }
          '';
        };
      };
    };
}
