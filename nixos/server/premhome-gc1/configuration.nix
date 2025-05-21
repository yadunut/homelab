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
  ];

  networking = {
    nameservers = [ "1.1.1.1" "8.8.8.8" ];
    firewall = {
      enable = true;
      allowedTCPPorts = [22 80 443];
    };
    interfaces.ens3 = {
      ipv4 = {
        addresses = [
          {
            address = "167.253.159.47";
            prefixLength = 25;
          }
        ];

        # Gateway Configuration
        routes = [
          {
            address = "0.0.0.0";
            prefixLength = 0;
            via = "167.253.159.126";
          }
        ];
      };
    };
  };

  system.stateVersion = "24.11";
}
