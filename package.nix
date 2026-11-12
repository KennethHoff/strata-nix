# Strata, the MoE inference engine with a VRAM/RAM/SSD expert cache, built for
# AMD GPUs through HIP.
#
# ## Why gfx1030 by default
#
# nixpkgs' rocBLAS has no gfx1032 (RX 6600) kernels, and Strata's CMake knows
# gfx1030 but not gfx1032, so RDNA2 cards below the 6800 run this build with
# HSA_OVERRIDE_GFX_VERSION=10.3.0. Strata's own tests pass on an RX 6600 that
# way, apart from CPU-side bit-exactness checks against ggml on AVX2.
#
# ## Why gyroPromptKernels is off by default
#
# Gyro's trellis prompt kernels are validated only on gfx1151. On an RX 6600
# they hung the GPU partway through a 7.4K-token prompt in every run, also with
# STRATA_HIP_ADAPT_KERNEL_COPY and STRATA_HIP_PROMPT_F16; without them the same
# prompt read cleanly in 5 of 5 runs at ~158 tok/s.
#
# ## Why llama.cpp is a second pin
#
# The engine builds from the ggml Strata ships in third_party/strata-ggml, but
# its tools (strata-iq-pack among them) read GGUF files with llama.cpp's
# gguf-py, which Strata's setup.py downloads at its LLAMA_CPP_COMMIT.
# ./versions.nix pins that commit, and the build fails loud when setup.py
# names another.
#
# ## Layout
#
# bin/strata is the engine. bin/strata-server is Strata's Python server
# (OpenAI and Anthropic APIs plus a web UI), which starts the engine from a
# JSON config. bin/strata-iq-pack prepares a pack from a native GGUF; build
# packs with the strata-iq-pack package (./iq-pack.nix) instead, so they
# outlive engine rebuilds.
# share/strata is the source tree: the server and tools resolve data/, serve/
# and tools/ relative to their own files.
{
  lib,
  stdenv,
  cmake,
  ninja,
  makeWrapper,
  python3,
  rocmPackages,
  callPackage,
  gpuTargets ? [ "gfx1030" ],
  gyroPromptKernels ? false,
}:
let
  sources = callPackage ./sources.nix { };
  inherit (sources)
    version
    src
    llamaCpp
    llamaCppRev
    ;
  python = callPackage ./python.nix { };
in
stdenv.mkDerivation {
  pname = "strata";
  inherit version src;

  nativeBuildInputs = [
    cmake
    ninja
    makeWrapper
    python3
  ];
  buildInputs = with rocmPackages; [
    clr
    hipblas
    hipblas-common
    hipblaslt
    rocblas
    rocprim
    hipcub
  ];

  postPatch = ''
    pinned=$(sed -n 's/^LLAMA_CPP_COMMIT = "\([0-9a-f]\{40\}\)".*/\1/p' setup.py)
    if [ "$pinned" != "${llamaCppRev}" ]; then
      echo "Strata's setup.py pins llama.cpp $pinned but versions.nix has ${llamaCppRev}; run nix run .#update" >&2
      exit 1
    fi
  '';

  cmakeFlags = [
    (lib.cmakeBool "STRATA_ENABLE_HIP" true)
    (lib.cmakeBool "STRATA_ENABLE_CUDA" false)
    (lib.cmakeBool "STRATA_PREFILL_MMQ" true)
    (lib.cmakeBool "STRATA_MMQ_TQ_OVERLAY" gyroPromptKernels)
    (lib.cmakeBool "STRATA_BUILD_TESTS" false)
    (lib.cmakeFeature "CMAKE_HIP_ARCHITECTURES" (lib.concatStringsSep ";" gpuTargets))
    (lib.cmakeFeature "CMAKE_HIP_COMPILER" "${rocmPackages.clr.hipClangPath}/clang++")
  ];
  ninjaFlags = [ "strata" ];

  installPhase = ''
    runHook preInstall

    install -Dm755 strata $out/bin/strata
    mkdir -p $out/share/strata
    cp -r $src/. $out/share/strata/

    makeWrapper ${lib.getExe python} $out/bin/strata-server \
      --add-flags "-m serve.server --engine strata" \
      --prefix PYTHONPATH : $out/share/strata
    makeWrapper ${lib.getExe python} $out/bin/strata-iq-pack \
      --add-flags $out/share/strata/tools/iq_pack.py \
      --set STRATA_GGUF_PY ${llamaCpp}/gguf-py

    runHook postInstall
  '';

  passthru = {
    inherit python llamaCpp;
    ggufPy = "${llamaCpp}/gguf-py";
  };

  meta = {
    description = "MoE inference engine with a VRAM/RAM/SSD expert cache (HIP build)";
    homepage = "https://github.com/Niko1221/Strata";
    license = lib.licenses.mit;
    mainProgram = "strata-server";
    platforms = [ "x86_64-linux" ];
  };
}
