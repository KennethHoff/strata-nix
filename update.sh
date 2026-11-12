#!/usr/bin/env bash
set -euo pipefail

# Run via `nix run .#update`. The wrapper provides git, curl, jq, sed and nix
# on PATH.
#
# Strata's tools read GGUF files with llama.cpp's gguf-py, which its setup.py
# downloads at the commit it names in LLAMA_CPP_COMMIT; that pin is read from
# the newest release tag so both move together.

TAG=$(git ls-remote --tags --refs https://github.com/Niko1221/Strata 'v*' \
  | sed 's|.*refs/tags/||' | grep -E '^v[0-9]+(\.[0-9]+)+$' | sort -V | tail -1)
VERSION=${TAG#v}
echo "Latest version: $VERSION"

prefetch() {
  nix store prefetch-file --unpack --json "$1" | jq -r .hash
}

SRC_HASH=$(prefetch "https://github.com/Niko1221/Strata/archive/refs/tags/${TAG}.tar.gz")
echo "srcHash: $SRC_HASH"

LLAMA_CPP_REV=$(curl -fsSL "https://raw.githubusercontent.com/Niko1221/Strata/${TAG}/setup.py" \
  | sed -n 's/^LLAMA_CPP_COMMIT = "\([0-9a-f]\{40\}\)".*/\1/p')
if [ -z "$LLAMA_CPP_REV" ]; then
  echo "No LLAMA_CPP_COMMIT found in Strata ${TAG}'s setup.py" >&2
  exit 1
fi
echo "llamaCppRev: $LLAMA_CPP_REV"

LLAMA_CPP_HASH=$(prefetch "https://github.com/ggml-org/llama.cpp/archive/${LLAMA_CPP_REV}.tar.gz")
echo "llamaCppHash: $LLAMA_CPP_HASH"

cat > versions.nix <<NIX
{
  version = "${VERSION}";
  srcHash = "${SRC_HASH}";
  llamaCppRev = "${LLAMA_CPP_REV}";
  llamaCppHash = "${LLAMA_CPP_HASH}";
}
NIX

echo "Done."
