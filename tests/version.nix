# The engine binary starts and the server's wrapper finds its Python modules:
# the HIP build linked and share/strata holds the server tree.
{ pkgs, self, ... }:
pkgs.runCommand "strata-version-test"
  {
    strata = self.packages.${pkgs.stdenv.hostPlatform.system}.strata;
  }
  ''
    set -euo pipefail
    export HOME="$PWD/home"
    mkdir -p "$HOME"

    "$strata/bin/strata" --help >/dev/null
    "$strata/bin/strata-server" --help >/dev/null

    mkdir -p "$out"
  ''
