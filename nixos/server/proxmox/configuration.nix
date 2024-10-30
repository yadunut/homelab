{
  config,
  meta,
  pkgs,
  ...
}: {
  imports = [../../common/users.nix ../../common/zerotier.nix];
  nix = {
    settings.experimental-features = ["nix-command" "flakes"];
  };

  nixpkgs.config.allowUnfree = true;

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
    firewall = {
      enable = true;
      allowedTCPPorts = [22];
    };
  };

  services.k3s = {
    enable = true;
    role = meta.role;
    tokenFile = config.age.secrets.k3s.path;
    clusterInit = false;
    serverAddr = "https://${meta.server-addr}:6443";
    extraFlags = ["--disable=servicelb" "--disable=traefik" "--node-ip ${meta.zt-ip}" "--flannel-iface ztxh6lvd6t" "--tls-san ${meta.zt-ip}"];
  };

  system.stateVersion = "24.11";
}
