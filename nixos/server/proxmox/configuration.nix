{
  meta,
  pkgs,
  ...
}: {
  imports = [../../common/users.nix ../../common/zerotier.nix];
  nix = {
    settings.experimental-features = ["nix-command" "flakes"];
  };

  networking.hostName = meta.hostname;

  age.secrets.k3s.file = ../../secrets/k3s.age;

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

  networking = {
    nftables.enable = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [22];
      trustedInterfaces = ["zts23oi5io"];
    };
  };

  # services.k3s = {
  #   enable = true;
  #   role = "server";
  #   tokenFile = config.age.secrets.k3s.path;
  #   clusterInit = false;
  #   serverAddr = "https://${meta.server-addr}:6443";
  #   extraFlags = ["--disable=servicelb" "--disable=traefik" "--node-ip ${meta.zt-ip}" "--flannel-iface zts23oi5io"];
  # };

  system.stateVersion = "24.11";
}
