# strata-iq-pack starts and finds its imports (gguf_reader beside it, gguf-py
# through STRATA_GGUF_PY) without the engine.
{ pkgs, self, ... }:
pkgs.runCommand "strata-iq-pack-test"
  {
    iqPack = self.packages.${pkgs.stdenv.hostPlatform.system}.strata-iq-pack;
  }
  ''
    set -euo pipefail
    "$iqPack/bin/strata-iq-pack" --help | grep -q -- --gguf
    mkdir -p "$out"
  ''
