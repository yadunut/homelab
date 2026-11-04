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

      linkHasNode = link: link.a.node == hostName || link.b.node == hostName;
      peerSide = link: if link.a.node == hostName then link.b else link.a;
      localLinks = lib.filterAttrs (_name: link: linkHasNode link) cfg.links;
      requiredLocalLinks = lib.filterAttrs (
        _name: link: cfg.nodes.${(peerSide link).node}.publicIp != null
      ) localLinks;
      coreInterfaces = lib.attrNames localLinks;
      requiredCoreInterfaces = lib.attrNames requiredLocalLinks;
      wireGuardUnits = map (interface: "wireguard-${interface}.service") coreInterfaces;

      nodeNames = lib.attrNames cfg.nodes;
      nodeIndexes = lib.imap1 (index: name: {
        inherit index name;
      }) nodeNames;
      localNodeIndex = (lib.findFirst (node: node.name == hostName) { index = 254; } nodeIndexes).index;

      localNode = cfg.nodes.${hostName};
      localLoopbackCidr = "${localNode.nodeIp}/128";
      remoteLoopbackCidrs = lib.mapAttrsToList (_name: node: "${node.nodeIp}/128") (
        lib.filterAttrs (name: _node: name != hostName) cfg.nodes
      );
      requiredRemoteLoopbackAddresses = lib.mapAttrsToList (_name: node: node.nodeIp) (
        lib.filterAttrs (name: node: name != hostName && node.publicIp != null) cfg.nodes
      );
      allLoopbackCidrs = lib.mapAttrsToList (_name: node: "${node.nodeIp}/128") cfg.nodes;
      podCidrPrefixPattern = "${config.nut.kubernetes.clusterCIDR}{64,128}";

      mkPrefixSet = prefixes: "[ ${lib.concatStringsSep ", " prefixes} ]";

      mkRouteFilter = name: prefixes: ''
        filter ${name} {
        ${
          if prefixes == [ ] then
            "  reject;"
          else
            ''
              if net ~ ${mkPrefixSet prefixes} then accept;
              reject;
            ''
        }
        }
      '';

      mkFilter = name: condition: ''
        filter ${name} {
          if ${condition} then accept;
          reject;
        }
      '';

      mkBabelInterface = interface: ''
        interface "${interface}" {
          type tunnel;
        };
      '';

      localLinkLocalAddress = link: if link.a.node == hostName then "fe80::1/64" else "fe80::2/64";

      mkInterfaceCheck = interface: link: ''
        ip link show dev "${interface}" >/dev/null
        ip -o -6 addr show dev "${interface}" scope link | grep -Fq "inet6 ${localLinkLocalAddress link}"
      '';

      mkNeighborCheck = interface: ''
        birdc show babel neighbors | grep -Fq "${interface}"
      '';

      mkRouteCheck = address: ''
        ip -6 route show exact "${address}/128" | grep -Fq "${address}"
      '';

      readinessScript = pkgs.writeShellScript "kubernetes-core-network-ready" ''
        set -euo pipefail

        check_core_network() {
          ip -o -6 addr show dev lo | grep -Fq "inet6 ${localLoopbackCidr}"
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkInterfaceCheck localLinks)}
          birdc show status >/dev/null
          ${lib.concatMapStringsSep "\n" mkNeighborCheck requiredCoreInterfaces}
          ${lib.concatMapStringsSep "\n" mkRouteCheck requiredRemoteLoopbackAddresses}
        }

        until check_core_network; do
          sleep 2
        done
      '';
    in
    {
      config = lib.mkIf isCoreNode {
        networking.interfaces.lo.ipv6.addresses = [
          {
            address = localNode.nodeIp;
            prefixLength = 128;
          }
        ];

        networking.firewall.extraForwardRules = lib.concatMapStringsSep "\n" (interface: ''
          iifname "${interface}" accept
          oifname "${interface}" accept
        '') coreInterfaces;
        services.bird = {
          enable = true;
          package = pkgs.bird3;
          config = ''
            log syslog all;

            router id 10.255.0.${toString localNodeIndex};

            protocol device {
              scan time 10;
            }

            ${mkRouteFilter "core_local_loopback" [ localLoopbackCidr ]}
            ${mkRouteFilter "core_remote_loopbacks" remoteLoopbackCidrs}
            ${mkRouteFilter "core_all_loopbacks" allLoopbackCidrs}
            ${mkFilter "core_pod_routes" "net ~ [ ${podCidrPrefixPattern} ]"}
            filter core_kernel_exports {
              if net ~ ${mkPrefixSet remoteLoopbackCidrs} || (source = RTS_BABEL && net ~ [ ${podCidrPrefixPattern} ]) then {
                krt_prefsrc = ${localNode.nodeIp};
                accept;
              }
              reject;
            }
            ${mkFilter "core_babel_imports" "net ~ ${mkPrefixSet remoteLoopbackCidrs} || net ~ [ ${podCidrPrefixPattern} ]"}
            ${mkFilter "core_babel_exports" "net ~ ${mkPrefixSet allLoopbackCidrs} || net ~ [ ${podCidrPrefixPattern} ]"}

            protocol direct core_direct {
              ipv6 {
                import filter core_local_loopback;
              };
              interface "lo";
            }

            protocol bgp cilium_bgp {
              local ::1 port 1179 as 64512;
              neighbor ${localNode.nodeIp} as 64512;
              passive on;
              ipv6 {
                import filter core_pod_routes;
                export none;
              };
            }

            protocol kernel core_kernel {
              ipv6 {
                import none;
                export filter core_kernel_exports;
              };
            }

            protocol babel core_babel {
            ${lib.concatMapStringsSep "\n" mkBabelInterface coreInterfaces}
              ipv6 {
                import filter core_babel_imports;
                export filter core_babel_exports;
              };
            }
          '';
        };

        systemd.services.bird = {
          after = wireGuardUnits;
          wants = wireGuardUnits;
        };

        systemd.services.kubernetes-core-network-ready = {
          description = "Kubernetes core WireGuard/BIRD network readiness";
          after = [ "bird.service" ] ++ wireGuardUnits;
          wants = [ "bird.service" ] ++ wireGuardUnits;
          path = [
            config.services.bird.package
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.iproute2
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            TimeoutStartSec = 0;
            ExecStart = readinessScript;
          };
        };
      };
    };
}
