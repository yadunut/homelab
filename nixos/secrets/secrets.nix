let 
  keys = import ./keys.nix;
in
{
  "tailscale.age".publicKeys = builtins.attrValues keys;
  "k3s.age".publicKeys = builtins.attrValues keys;
  "flux.age".publicKeys = [ keys.yadunut keys.yadunut-mbp ];
}
