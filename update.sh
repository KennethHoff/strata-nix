#!/usr/bin/env bash
set -euo pipefail

# Run via `nix run .#update-strata`. The wrapper provides git, curl, jq, sed and
# nix on PATH.
#
# Strata's CMakeLists.txt pins the llama.cpp commit it takes ggml from, so the
# ggml pin is read from the newest release tag and both pins move together.

TAG=$(git ls-remote --tags --refs https://github.com/Niko1221/Strata 'v*' \
  | sed 's|.*refs/tags/||' | grep -E '^v[0-9]+(\.[0-9]+)+$' | sort -V | tail -1)
VERSION=${TAG#v}
echo "Latest version: $VERSION"

prefetch() {
  nix store prefetch-file --unpack --json "$1" | jq -r .hash
}

SRC_HASH=$(prefetch "https://github.com/Niko1221/Strata/archive/refs/tags/${TAG}.tar.gz")
echo "srcHash: $SRC_HASH"

GGML_REV=$(curl -fsSL "https://raw.githubusercontent.com/Niko1221/Strata/${TAG}/CMakeLists.txt" \
  | sed -n 's/.*GIT_TAG \([0-9a-f]\{40\}\).*/\1/p')
if [ -z "$GGML_REV" ]; then
  echo "No ggml GIT_TAG found in Strata ${TAG}'s CMakeLists.txt" >&2
  exit 1
fi
echo "ggmlRev: $GGML_REV"

GGML_HASH=$(prefetch "https://github.com/ggml-org/llama.cpp/archive/${GGML_REV}.tar.gz")
echo "ggmlHash: $GGML_HASH"

cat > versions.nix <<NIX
{
  version = "${VERSION}";
  srcHash = "${SRC_HASH}";
  ggmlRev = "${GGML_REV}";
  ggmlHash = "${GGML_HASH}";
}
NIX

echo "Done."
