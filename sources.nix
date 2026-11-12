# Strata's source and the llama.cpp commit its ggml comes from, as pinned in
# ./versions.nix. Shared by the engine and strata-iq-pack.
{ fetchzip, fetchFromGitHub }:
let
  inherit (import ./versions.nix)
    version
    srcHash
    ggmlRev
    ggmlHash
    ;
in
{
  inherit version ggmlRev;
  src = fetchzip {
    url = "https://github.com/Niko1221/Strata/archive/refs/tags/v${version}.tar.gz";
    hash = srcHash;
  };
  ggml = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    rev = ggmlRev;
    hash = ggmlHash;
  };
}
