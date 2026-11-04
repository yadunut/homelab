{
  flake.modules.nixos.kubernetes-common = {
    networking.firewall.allowedTCPPorts = [ 2200 ];
  };
}
