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
# ## Why ggml is a second pin
#
# Strata's CMake fetches llama.cpp's ggml at configure time, which a sandboxed
# build cannot; STRATA_GGML_DIR points it at ./versions.nix's copy instead. The
# Gyro prompt kernels are an overlay that turns itself off on any other ggml
# commit, so the build fails loud when the two pins drift apart.
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
    ggml
    ggmlRev
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
    pinned=$(sed -n 's/.*GIT_TAG \([0-9a-f]\{40\}\).*/\1/p' CMakeLists.txt)
    if [ "$pinned" != "${ggmlRev}" ]; then
      echo "Strata pins ggml $pinned but versions.nix has ${ggmlRev}; run nix run .#update" >&2
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
    (lib.cmakeFeature "STRATA_GGML_DIR" "${ggml}")
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
      --set STRATA_GGUF_PY ${ggml}/gguf-py

    runHook postInstall
  '';

  passthru = {
    inherit python ggml;
    ggufPy = "${ggml}/gguf-py";
  };

  meta = {
    description = "MoE inference engine with a VRAM/RAM/SSD expert cache (HIP build)";
    homepage = "https://github.com/Niko1221/Strata";
    license = lib.licenses.mit;
    mainProgram = "strata-server";
    platforms = [ "x86_64-linux" ];
  };
}
