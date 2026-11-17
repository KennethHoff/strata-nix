# strata-dflash2: Inco AI's DFlash2 drafter for Qwen3.8-Flash-Next, packed
# for the engine by Strata's tools/dflash2_pack.py. services.strata.dflash2
# takes this directory.
#
# ## Why two packs
#
# The server accepts the drafter only when the Q4_0 pack is on disk, and
# starts the engine with the converted one (Q4_0 selector codebooks, 174 MiB
# less VRAM) when it is there too. It checks both against the sizes and
# SHA-256 it pins, which this revision and these flags reproduce.
{
  lib,
  fetchurl,
  runCommand,
  callPackage,
}:
let
  sources = callPackage ./sources.nix { };
  python = callPackage ./python.nix { };
  rev = "a22a1744";
  base = "https://huggingface.co/incoai/Qwen3.8-Flash-Next-DFlash2/resolve/${rev}";
  weights = fetchurl {
    url = "${base}/model.safetensors";
    hash = "sha256-1nI/KjWerzPsDJXyKujt2olndAIMVSKWqF4ZE7TTGG8=";
  };
  config = fetchurl {
    url = "${base}/config.json";
    hash = "sha256-JAlXWYb56iTUVTQ+tGnA5pQN717asdG+UDu460zDsbk=";
  };
  pack = "${lib.getExe python} ${sources.src}/tools/dflash2_pack.py ${weights} ${config}";
in
runCommand "strata-dflash2-${rev}"
  {
    passthru = { inherit weights config; };
    meta = {
      description = "DFlash2 drafter for Qwen3.8-Flash-Next, packed for Strata";
      homepage = "https://huggingface.co/incoai/Qwen3.8-Flash-Next-DFlash2";
      license = lib.licenses.asl20;
      platforms = lib.platforms.linux;
    };
  }
  ''
    mkdir -p $out
    ${pack} $out/qwen3.8-flash-next-dflash2.q4_0.pack --q4_0
    ${pack} $out/qwen3.8-flash-next-dflash2.q4_0-selq4.pack --q4_0 --q4_0-selector
  ''
