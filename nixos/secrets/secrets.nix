let 
  keys = import ./keys.nix;
in
{
  "tailscale.age".publicKeys = builtins.attrValues keys;
}
