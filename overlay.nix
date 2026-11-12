final: _: {
  strata = final.callPackage ./package.nix { };
  strata-iq-pack = final.callPackage ./iq-pack.nix { };
}
