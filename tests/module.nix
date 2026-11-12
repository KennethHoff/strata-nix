# services.strata turns its options into a strata.service that runs the
# server on the configured address with an engine config holding them, and
# importing it puts strata-iq-pack on pkgs. `model` fills in the tokenizer and
# the pack arguments, and leaves them alone when unset. `vision` adds --vision
# and a `vision` section that reads the model's GGUF.
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
    (expect "an explicit tokenizer wins over model" (
      withModelAndTokenizer.tokenizer == "/elsewhere/tokenizer"
    ))
  ];
in
pkgs.runCommand "strata-module-test" { nativeBuildInputs = [ pkgs.jq ]; } ''
  echo ${lib.escapeShellArgs results}
  # The server reads AMD cards and keeps CUDA-only engine settings off only
  # when its config names the HIP backend.
  jq -e '.backend == "hip"' ${engineConfig} > /dev/null \
    || { echo "strata module check failed: engine config names the hip backend"; exit 1; }
  mkdir -p "$out"
''
