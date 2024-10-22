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

  networking.hostName = "premhome-gc1";

  age.secrets.k3s.file = ../../secrets/k3s.age;

  boot.loader.grub.enable = true;
  # grub.device is set by disko
  boot.tmp.cleanOnBoot = true;

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
  };

  services.openssh.enable = true;
  services.qemuGuest.enable = true;

  environment.systemPackages = with pkgs; [
    git
    neovim
    wget
    jq
    ripgrep
    fd
  ];

  networking = {
    nftables.enable = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [22 80 443];
      trustedInterfaces = ["zts23oi5io"];
    };
  };

  services.k3s = {
    enable = true;
    role = "server";
    tokenFile = config.age.secrets.k3s.path;
    clusterInit = true;
    extraFlags = ["--disable=servicelb" "--disable=traefik" "--node-ip ${meta.zt-ip}" "--flannel-iface zts23oi5io"];
  };

  system.stateVersion = "24.11";
}
