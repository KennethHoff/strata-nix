# strata-vision, Strata's picture reader: tools/vision over llama.cpp's mtmd at
# the ggml commit the engine pins. The server starts it from the config's
# `vision` section, hands it each picture and gives the engine the embeddings
# it writes back. For Qwen3.8-Flash-Next and its quants (Gyro included) it
# reads the model's mmproj file and only the vocabulary of the text GGUF.
#
# ## Why the CPU reader only
#
# Strata itself reads pictures on the CPU for cards under 24 GB: the GPU reader
# (strata-vision-hip) keeps 1-1.4 GB of VRAM that the expert cache would use.
# The CPU reader also needs no ROCm, so it builds in minutes and does not
# change when the engine is rebuilt for another GPU.
#
# ## Why portable
#
# STRATA_PORTABLE=OFF builds with -march=native, which ties the output to the
# builder's CPU. The portable AVX2 baseline is the same on every builder and
# is what Strata's own release readers ship with.
{
  lib,
  stdenv,
  cmake,
  ninja,
  callPackage,
}:
let
  sources = callPackage ./sources.nix { };
in
stdenv.mkDerivation {
  pname = "strata-vision";
  inherit (sources) version src;

  nativeBuildInputs = [
    cmake
    ninja
  ];

  cmakeDir = "../tools/vision";
  cmakeFlags = [
    (lib.cmakeFeature "LLAMA_DIR" "${sources.ggml}")
    (lib.cmakeBool "STRATA_PORTABLE" true)
    (lib.cmakeBool "STRATA_VISION_CUDA" false)
    (lib.cmakeBool "STRATA_VISION_HIP" false)
  ];
  ninjaFlags = [ "strata-vision" ];

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/strata-vision $out/bin/strata-vision
    runHook postInstall
  '';

  meta = {
    description = "Strata's picture reader (llama.cpp mtmd), which turns images into embeddings for the engine";
    homepage = "https://github.com/Niko1221/Strata";
    license = lib.licenses.mit;
    mainProgram = "strata-vision";
    platforms = lib.platforms.linux;
  };
}
