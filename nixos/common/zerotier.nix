{config}: {
  age.secrets.zerotier.file = ../../secrets/zerotier.age;

  services.zerotierone = {
    enable = true;
    joinNetworks = [builtins.readFile config.age.secrets.zerotier.path]; # Is an antipattern, but idc if this is readable on the servers
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
