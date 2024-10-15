{
  config,
  pkgs,
  ...
}: {
  imports = [../../common/users.nix];
  nix = {
    settings.experimental-features = ["nix-command" "flakes"];
  };

  networking.hostName = "premhome-gc1";

  age.secrets.k3s.file = ../../secrets/k3s.age;

  boot.loader.grub.enable = true;
  # grub.device is set by disko
  boot.tmp.cleanOnBoot = true;

  services.openssh.enable = true;
  services.qemuGuest.enable = true;

  environment.systemPackages = with pkgs; [
    git
    neovim
    wget
  ];

  system.stateVersion = "24.11";
}
