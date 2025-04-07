{
  users.users.yadunut = {
    isNormalUser = true;
    extraGroups = ["wheel"]; # Enable ‘sudo’ for the user.
    openssh.authorizedKeys.keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJXOpmWsAnl2RtOuJJMRUx+iJTwf2RWJ1iS3FqXJFzFG"];
  };
  security.sudo.wheelNeedsPassword = false;

  users.users.root.openssh.authorizedKeys.keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJXOpmWsAnl2RtOuJJMRUx+iJTwf2RWJ1iS3FqXJFzFG"];
  users.users.root.hashedPassword = "$6$xa/mFg4OxIbb8XiQ$S2RVyCKcLaKHymFs48u8vj1dv.mQdxt.BQoucJsr8wfcHayXwKfD0C2NIOYY5AEPR9zgnMvFp8d8STKe6wMGR/";
}
