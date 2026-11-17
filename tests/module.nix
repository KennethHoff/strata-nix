# services.strata turns its options into a strata.service that runs the
# server on the configured address with an engine config holding them, and
# importing it puts strata-iq-pack on pkgs. `model` fills in the tokenizer and
# the pack arguments, and leaves them alone when unset. `vision` adds --vision
# and a `vision` section that reads the model's GGUF. `drafting` and
# `userArgs` reach the engine config only when set, and `dflash2` serves the
# model from a folder that also links the drafter packs.
# Evaluation only: the package's path is compared without building it.
{
  pkgs,
  self,
  nixpkgs,
  ...
}:
let
  inherit (pkgs) lib;
  evalWith =
    strata:
    nixpkgs.lib.nixosSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        self.nixosModules.default
        {
          boot.isContainer = true;
          system.stateVersion = "26.05";
          services.strata = {
            enable = true;
            modelName = "test-model";
          }
          // strata;
        }
      ];
    };

  manual = evalWith {
    host = "0.0.0.0";
    port = 9000;
    tokenizer = "/models/tokenizer";
    args = [
      "--pack"
      "/models/pack"
    ];
  };
  service = manual.config.systemd.services.strata;
  execStart = builtins.unsafeDiscardStringContext service.serviceConfig.ExecStart;
  engineConfig = builtins.elemAt (lib.splitString " " service.serviceConfig.ExecStart) 2;
  strata = builtins.unsafeDiscardStringContext (toString manual.config.services.strata.package);

  withModel =
    (evalWith {
      model = "/srv/strata/m";
      args = [
        "--kv"
        "int8"
      ];
    }).config.services.strata;
  withModelAndTokenizer =
    (evalWith {
      model = "/srv/strata/m";
      tokenizer = "/elsewhere/tokenizer";
    }).config.services.strata;

  withSplit =
    (evalWith {
      model = "/srv/strata/m";
      nativeGguf = "/srv/strata/m/M-00001-of-00002.gguf";
      vision = {
        enable = true;
        mmproj = "/srv/strata/mmproj.gguf";
      };
    }).config.services.strata;
  withPle =
    (evalWith {
      model = "/srv/strata/m";
      pleGguf = "/srv/strata/ple.gguf";
    }).config.services.strata;

  withVision =
    (evalWith {
      model = "/srv/strata/m";
      vision = {
        enable = true;
        mmproj = "/srv/strata/mmproj.gguf";
        threads = 4;
      };
    }).config;
  visionConfig = withVision.services.strata.engineSettings;

  draftingOf = value: (evalWith { drafting = value; }).config.services.strata.engineSettings.drafting;
  withUserArgs =
    (evalWith {
      userArgs = [
        "--spec"
        "8"
        "--draft-conf"
        "0.7"
      ];
    }).config.services.strata;
  withDrafter =
    (evalWith {
      model = "/srv/strata/m";
      dflash2 = "/srv/strata/drafter";
      pleGguf = "/srv/strata/ple.gguf";
      vision = {
        enable = true;
        mmproj = "/srv/strata/mmproj.gguf";
      };
    }).config.services.strata;
  drafterPack = builtins.elemAt withDrafter.args 1;
  drafterRoot = dirOf (dirOf drafterPack);
  drafterWithoutModel =
    (evalWith {
      dflash2 = "/srv/strata/drafter";
      tokenizer = "/models/tokenizer";
      args = [
        "--pack"
        "/models/pack"
      ];
    }).config.services.strata;

  expect = name: ok: if ok then name else throw "strata module check failed: ${name}";
  results = [
    (expect "runs strata-server" (lib.hasPrefix "${strata}/bin/strata-server --config " execStart))
    (expect "binds the configured address" (lib.hasSuffix " --host 0.0.0.0 --port 9000" execStart))
    (expect "not started at boot by default" (service.wantedBy == [ ]))
    (expect "swap off" (service.serviceConfig.MemorySwapMax == 0))
    (expect "adds pkgs.strata-iq-pack" (manual.pkgs ? strata-iq-pack))
    (expect "no model leaves args as given" (
      manual.config.services.strata.args == [
        "--pack"
        "/models/pack"
      ]
    ))
    (expect "model sets the tokenizer" (withModel.tokenizer == "/srv/strata/m/pack/tokenizer"))
    (expect "model puts pack and native first" (
      withModel.args == [
        "--pack"
        "/srv/strata/m/pack"
        "--native"
        "/srv/strata/m/model.gguf"
        "--kv"
        "int8"
      ]
    ))
    (expect "no vision section by default" (!(manual.config.services.strata.engineSettings ? vision)))
    (expect "vision adds --vision last" (lib.last withVision.services.strata.args == "--vision"))
    (expect "vision reads the model's GGUF" (visionConfig.vision.model == "/srv/strata/m/model.gguf"))
    (expect "vision runs the CPU reader" (
      visionConfig.vision.gpu == false
      && lib.hasSuffix "/bin/strata-vision" visionConfig.vision.exe
      && visionConfig.vision.mmproj == "/srv/strata/mmproj.gguf"
      && visionConfig.vision.max_tokens == 300
      && visionConfig.vision.threads == 4
    ))
    (expect "nativeGguf replaces model.gguf for --native and pictures" (
      lib.take 4 withSplit.args == [
        "--pack"
        "/srv/strata/m/pack"
        "--native"
        "/srv/strata/m/M-00001-of-00002.gguf"
      ]
      && withSplit.engineSettings.vision.model == "/srv/strata/m/M-00001-of-00002.gguf"
    ))
    (expect "no table flags without pleGguf" (
      !(builtins.elem "--ple-gguf" withModel.args)
      && !(builtins.elem "--native-dense-gguf" withModel.args)
    ))
    (expect "pleGguf adds the table and names the weights' source" (
      withPle.args == [
        "--pack"
        "/srv/strata/m/pack"
        "--native"
        "/srv/strata/m/model.gguf"
        "--ple-gguf"
        "/srv/strata/ple.gguf"
        "--native-dense-gguf"
        "/srv/strata/m/model.gguf"
      ]
    ))
    (expect "an explicit tokenizer wins over model" (
      withModelAndTokenizer.tokenizer == "/elsewhere/tokenizer"
    ))
    (expect "no drafting key by default" (!(manual.config.services.strata.engineSettings ? drafting)))
    (expect "drafting dflash2 reaches the engine config" (draftingOf "dflash2" == "dflash2"))
    (expect "drafting off reaches the engine config" (draftingOf "off" == "off"))
    (expect "drafting auto reaches the engine config" (draftingOf "auto" == "auto"))
    (expect "drafting mtp reaches the engine config" (draftingOf "mtp" == "mtp"))
    (expect "no user_args key by default" (!(manual.config.services.strata.engineSettings ? user_args)))
    (expect "userArgs become user_args in order" (
      withUserArgs.engineSettings.user_args == [
        "--spec"
        "8"
        "--draft-conf"
        "0.7"
      ]
    ))
    (expect
      "dflash2 passes --pack as model/pack inside a folder the module builds, not the model directory"
      (
        builtins.elemAt withDrafter.args 0 == "--pack"
        && lib.hasSuffix "/model/pack" drafterPack
        && drafterRoot != "/srv/strata/m"
      )
    )
    (expect "dflash2 keeps --native at the model directory's model.gguf" (
      builtins.elemAt withDrafter.args 2 == "--native"
      && builtins.elemAt withDrafter.args 3 == "/srv/strata/m/model.gguf"
    ))
    (expect "dflash2 keeps the tokenizer at the model directory's pack/tokenizer" (
      withDrafter.tokenizer == "/srv/strata/m/pack/tokenizer"
    ))
    (expect "dflash2 keeps vision reading the model directory's model.gguf" (
      withDrafter.engineSettings.vision.model == "/srv/strata/m/model.gguf"
    ))
    (expect "dflash2 keeps --ple-gguf and --native-dense-gguf right after --native" (
      lib.sublist 2 6 withDrafter.args == [
        "--native"
        "/srv/strata/m/model.gguf"
        "--ple-gguf"
        "/srv/strata/ple.gguf"
        "--native-dense-gguf"
        "/srv/strata/m/model.gguf"
      ]
    ))
    (expect "dflash2 without model leaves args as given" (
      drafterWithoutModel.args == [
        "--pack"
        "/models/pack"
      ]
    ))
  ];
in
pkgs.runCommand "strata-module-test" { nativeBuildInputs = [ pkgs.jq ]; } ''
  echo ${lib.escapeShellArgs results}
  # The server reads AMD cards and keeps CUDA-only engine settings off only
  # when its config names the HIP backend.
  jq -e '.backend == "hip"' ${engineConfig} > /dev/null \
    || { echo "strata module check failed: engine config names the hip backend"; exit 1; }
  # The server looks for the drafter in dflash2/ two levels above --pack.
  [ "$(readlink ${drafterRoot}/model)" = /srv/strata/m ] \
    || { echo "strata module check failed: dflash2 puts a model symlink to the directory the model option names two levels above --pack"; exit 1; }
  [ "$(readlink ${drafterRoot}/dflash2)" = /srv/strata/drafter ] \
    || { echo "strata module check failed: dflash2 puts a dflash2 symlink to the directory the dflash2 option names two levels above --pack"; exit 1; }
  mkdir -p "$out"
''
