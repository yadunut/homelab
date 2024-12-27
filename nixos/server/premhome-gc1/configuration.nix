{
  config,
  pkgs,
  ...
}: {
  imports = [../../common/users.nix ../../common/zerotier.nix ../../common/k3s.nix];
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

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };
  services.qemuGuest.enable = true;

  environment.systemPackages = with pkgs; [
    git
    neovim
    wget
    jq
    ripgrep
    fd
    nfs-utils
  ];

  networking = {
    firewall = {
      enable = true;
      allowedTCPPorts = [22 80 443];
    };
  };

  # For longhorn
  services.openiscsi = {
    enable = true;
    name = "iqn.2016-04.com.open-iscsi:${config.networking.hostName}";
  };
  systemd.tmpfiles.rules = [
    "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
  ];

  system.stateVersion = "24.11";
}
