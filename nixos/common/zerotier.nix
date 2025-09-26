{...}: {
  services.zerotierone = {
    enable = true;
    joinNetworks = ["23992b9a659115b6"];
  };

  networking = {
    firewall = {
      trustedInterfaces = ["ztxh6lvd6t"];
    };
  };
}
