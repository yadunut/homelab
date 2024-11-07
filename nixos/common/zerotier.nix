{...}: {
  services.zerotierone = {
    enable = true;
    joinNetworks = ["<network-id>"];
  };

  networking = {
    firewall = {
      trustedInterfaces = ["ztxh6lvd6t"];
    };
  };
}
