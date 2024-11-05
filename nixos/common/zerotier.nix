{...}: {
  services.zerotierone = {
    enable = true;
  };

  networking = {
    firewall = {
      trustedInterfaces = ["ztxh6lvd6t"];
    };
  };
}
