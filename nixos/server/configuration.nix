{ config, meta, pkgs, ... }:
{
  imports = [../common/users.nix];
  nix = {
    settings.experimental-features = ["nix-command" "flakes"];
  };

  networking.hostName = meta.hostname;

  age.secrets.tailscale.file = ../secrets/tailscale.age;

  services.tailscale = {
    enable = true;
    authKeyFile = config.age.secrets.tailscale.path;
    extraUpFlags = [ "--login-server" "http://ts.yadunut.com:444" ];
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  services.openssh.enable = true;
  services.qemuGuest.enable = true;

  environment.systemPackages = with pkgs; [
    git
    neovim
    wget
    k3s
  ];

  system.stateVersion = "24.11";
}
