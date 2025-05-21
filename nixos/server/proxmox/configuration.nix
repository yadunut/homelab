{
  meta,
  pkgs,
  ...
}: {
  imports = [../../common/users.nix ../../common/zerotier.nix ../../common/k3s.nix];
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

  environment.systemPackages = with pkgs; [
    git
    neovim
    wget
    jq
    ripgrep
    fd
  ];

  networking = {
    firewall = {
      enable = true;
      allowedTCPPorts = [22];
    };
  };

  system.stateVersion = "24.11";
}
