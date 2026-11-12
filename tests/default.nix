# Checks, keyed by name. `module` only evaluates, so it is cheap; `version`
# builds Strata itself, ROCm and all.
{
  pkgs,
  self,
  nixpkgs,
}:
let
  args = { inherit pkgs self nixpkgs; };
in
{
  module = import ./module.nix args;
  version = import ./version.nix args;
}
