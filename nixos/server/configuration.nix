{ config, meta, pkgs, ... }:
{
  imports = [../common/users.nix];
  nix = {
    settings.experimental-features = ["nix-command" "flakes"];
  };

  networking.hostName = meta.hostname;

  age.secrets.tailscale.file = ../secrets/tailscale.age;
  age.secrets.k3s.file = ../secrets/k3s.age;

  services.tailscale = {
    enable = true;
    authKeyFile = config.age.secrets.tailscale.path;
    extraUpFlags = [ "--login-server" "http://ts.yadunut.com:444" ];
    interfaceName = "tailscale0";
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  services.openssh.enable = true;
  services.qemuGuest.enable = true;

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
    serverAddr = if meta.hostname == "premhome-falcon-1" then "" else "https://premhome-falcon-1:6443";
  };

  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.enable = false;

  system.stateVersion = "24.11";
}
