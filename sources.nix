# Strata's source, and the llama.cpp commit whose gguf-py its tools read GGUF
# files with, as pinned in ./versions.nix. Shared by the engine and
# strata-iq-pack.
{ fetchzip, fetchFromGitHub }:
let
  inherit (import ./versions.nix)
    version
    srcHash
    llamaCppRev
    llamaCppHash
    ;
in
{
  inherit version llamaCppRev;
  src = fetchzip {
    url = "https://github.com/Niko1221/Strata/archive/refs/tags/v${version}.tar.gz";
    hash = srcHash;
  };
  llamaCpp = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    rev = llamaCppRev;
    hash = llamaCppHash;
  };
}
