{config, ...}: {
  age.secrets.zerotier.file = ../secrets/zerotier-network.age;

  services.zerotierone = {
    enable = true;
  };

  networking = {
    firewall = {
      interfaces."zts23oi5io".allowedTCPPortRanges = [
        {
          from = 0;
          to = 65535;
        }
      ];
      interfaces."zts23oi5io".allowedUDPPortRanges = [
        {
          from = 0;
          to = 65535;
        }
      ];
    };
  };
}
