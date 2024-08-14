{  config, lib, pkgs, meta, ...}:
{
  imports = [./users.nix];

  nix = {
    settings.experimental-features = ["nix-command" "flakes"];
  };

  isoImage = {
    isoName = "${config.system.nixos.distroId}-yadunut.iso";
  };
  services.openssh.enable = true;

  services.qemuGuest.enable = true;

  environment.systemPackages = with pkgs; [
    git
    neovim
    wget
  ];

  system.stateVersion = "24.05";
}
