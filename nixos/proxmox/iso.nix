{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [../common/users.nix];

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
  boot.loader.timeout = lib.mkForce 0;

  system.stateVersion = "24.05";
}
