{
  config,
  meta,
  ...
}: {
  services.k3s = {
    enable = true;
    role = meta.role;
    tokenFile = config.age.secrets.k3s.path;
    clusterInit = config.networking.hostName == "premhome-gc1";
    serverAddr =
      if config.networking.hostName == "premhome-gc1"
      then ""
      else "https://${meta.server-addr}:6443";
    extraFlags = ["--disable=servicelb" "--disable=traefik" "--node-ip ${meta.zt-ip}" "--flannel-iface ztxh6lvd6t" "--flannel-backend=host-gw" "--tls-san ${meta.zt-ip}"];
  };
}
