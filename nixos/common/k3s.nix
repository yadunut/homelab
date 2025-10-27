{
  pkgs,
  config,
  meta,
  ...
}:
{
  services.k3s =
    let
      is_server = config.networking.hostName == "premhome-gc1";
    in
    {
      enable = true;
      role = if is_server then "server" else "agent";
      tokenFile = config.age.secrets.k3s.path;
      clusterInit = is_server;
      serverAddr = if is_server then "" else "https://${meta.server-addr}:6443";
      extraFlags =
        if is_server then
          [
            "--disable=servicelb"
            "--disable=traefik"
            "--node-ip ${meta.zt-ip}"
            "--flannel-iface ztxh6lvd6t"
            "--flannel-backend=host-gw"
            "--tls-san ${meta.zt-ip}"
          ]
        else
          [
            "--node-ip ${meta.zt-ip}"
            "--flannel-iface ztxh6lvd6t"
          ];
    };

  # For longhorn
  environment.systemPackages = [ pkgs.nfs-utils ];
  services.openiscsi = {
    enable = true;
    name = "iqn.2016-04.com.open-iscsi:${config.networking.hostName}";
  };
  systemd.tmpfiles.rules = [
    "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
  ];
}
