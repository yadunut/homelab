{
  config,
  meta,
  pkgs,
  ...
}: {
  imports = [../../common/users.nix];
  nix = {
    settings.experimental-features = ["nix-command" "flakes"];
  };

  networking.hostName = meta.hostname;

  age.secrets.tailscale.file = ../../secrets/tailscale.age;
  age.secrets.k3s.file = ../../secrets/k3s.age;

  services.tailscale = {
    enable = true;
    authKeyFile = config.age.secrets.tailscale.path;
    useRoutingFeatures = "both";
    extraUpFlags = ["--advertise-routes=10.0.1.0/24" "--login-server=http://ts.yadunut.com:444" "--accept-routes"];
    interfaceName = "tailscale0";
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.tmp.cleanOnBoot = true;

  services.openssh.enable = true;
  services.qemuGuest.enable = true;

  # For longhorn
  services.openiscsi = {
    enable = true;
    name = "iqn.2016-04.com.open-iscsi:${meta.hostname}";
  };
  systemd.tmpfiles.rules = [
    "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
  ];

  environment.systemPackages = with pkgs; [
    git
    neovim
    wget
  ];

  services.k3s = {
    enable = true;
    role = "server";
    tokenFile = config.age.secrets.k3s.path;
    clusterInit = meta.hostname == "premhome-falcon-1";
    serverAddr =
      if meta.hostname == "premhome-falcon-1"
      then ""
      else "https://premhome-falcon-1:6443";
    extraFlags = ["--disable=servicelb" "--disable=traefik"];
  };

  networking.firewall.trustedInterfaces = ["tailscale0"];
  networking.firewall.enable = false;

  system.stateVersion = "24.11";
}
