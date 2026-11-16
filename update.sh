#!/usr/bin/env bash
set -euo pipefail

# Run via `nix run .#update-strata`. The wrapper provides git, curl, jq, sed and
# nix on PATH.
#
# Strata vendors ggml at the llama.cpp commit third_party/ggml/VERSION.txt
# names; strata-iq-pack needs that commit's gguf-py, so both pins move together.

TAG=$(git ls-remote --tags --refs https://github.com/Niko1221/Strata 'v*' \
  | sed 's|.*refs/tags/||' | grep -E '^v[0-9]+(\.[0-9]+)+$' | sort -V | tail -1)
VERSION=${TAG#v}
echo "Latest version: $VERSION"

prefetch() {
  nix store prefetch-file --unpack --json "$1" | jq -r .hash
}

SRC_HASH=$(prefetch "https://github.com/Niko1221/Strata/archive/refs/tags/${TAG}.tar.gz")
echo "srcHash: $SRC_HASH"

GGML_REV=$(curl -fsSL "https://raw.githubusercontent.com/Niko1221/Strata/${TAG}/third_party/ggml/VERSION.txt" | cut -d" " -f1)
if [ -z "$GGML_REV" ]; then
  echo "No ggml commit found in Strata ${TAG}'s third_party/ggml/VERSION.txt" >&2
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
