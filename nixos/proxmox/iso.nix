{  config, lib, pkgs, meta, ...}:
let tailscale_key = builtins.getEnv "TAILSCALE_AUTH_KEY";
in {
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

  environment.etc."tailscale/preAuthKey".text = tailscale_key;

  services.tailscale = {
    enable = true;
    extraUpFlags = [ "--login-server" "http://ts.yadunut.com:444"];
    authKeyFile = "/etc/tailscale/preAuthKey";
  };

  system.stateVersion = "24.05";
}
