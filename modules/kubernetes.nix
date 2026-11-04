{ inputs, lib, ... }:
{
  # Evaluate in the consuming flake's module graph, using its package set,
  # machine registry, and secret generator helper.
  imports = [ (inputs.import-tree ./kubernetes) ];

  options.homelab.kubernetes = {
    adminAddress = lib.mkOption {
      type = lib.types.str;
      description = "Control-plane Yggdrasil address for administrative API access.";
    };
    publicAddresses = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr lib.types.str);
      description = "Public WireGuard endpoint addresses keyed by machine name.";
    };
    wireguardPublicKeys = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      description = "Existing Kubernetes WireGuard public keys keyed by machine name.";
    };
  };
}
