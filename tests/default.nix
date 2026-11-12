# Checks, keyed by name. `module` only evaluates and `iq-pack` needs no ROCm,
# so both are cheap; `version` builds Strata itself, ROCm and all.
{
  pkgs,
  self,
  nixpkgs,
}:
let
  args = { inherit pkgs self nixpkgs; };
in
{
  iq-pack = import ./iq-pack.nix args;
  module = import ./module.nix args;
  version = import ./version.nix args;
}
