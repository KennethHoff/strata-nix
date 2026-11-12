# strata-iq-pack on its own: Strata's tools/iq_pack.py, which turns a native
# GGUF into the pack the engine's --pack reads.
#
# ## Why it is not just the engine's bin/strata-iq-pack
#
# Packing is Python over Strata's source and llama.cpp's gguf-py; it never runs the
# HIP engine. A pack built with this changes only when Strata's source or the
# llama.cpp pin does, not when the engine is rebuilt for another GPU or kernel set.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  callPackage,
}:
let
  sources = callPackage ./sources.nix { };
  python = callPackage ./python.nix { };
  ggufPy = "${sources.llamaCpp}/gguf-py";
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "strata-iq-pack";
  inherit (sources) version;

  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    makeWrapper ${lib.getExe python} $out/bin/strata-iq-pack \
      --add-flags ${sources.src}/tools/iq_pack.py \
      --set STRATA_GGUF_PY ${ggufPy}
    runHook postInstall
  '';

  passthru = {
    inherit python ggufPy;
    inherit (sources) src llamaCpp;
    mkPack = callPackage ./mk-pack.nix { strata-iq-pack = finalAttrs.finalPackage; };
  };

  meta = {
    description = "Strata's pack builder, which prepares a pack from a native GGUF";
    homepage = "https://github.com/Niko1221/Strata";
    license = lib.licenses.mit;
    mainProgram = "strata-iq-pack";
    platforms = lib.platforms.linux;
  };
})
