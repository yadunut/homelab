{
  flake.modules.nixos.kubernetes-common =
    {
      config,
      ...
    }:
    {
      services.openiscsi = {
        enable = true;
        name = "iqn.2016-04.com.open-iscsi:${config.networking.hostName}";
      };
      systemd.tmpfiles.rules = [
        "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
      ];
    };
}
