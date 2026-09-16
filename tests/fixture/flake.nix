{
  description = "rootless-nix-bootstrap smoke-test fixture";

  outputs = { self }: {
    lib.smoke = "ok";
  };
}
