# services.strata turns its options into a strata.service that runs the
# server on the configured address with an engine config holding them, and
# importing it puts strata-iq-pack on pkgs. `model` fills in the tokenizer and
# the pack arguments, and leaves them alone when unset.
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
    (expect "an explicit tokenizer wins over model" (
      withModelAndTokenizer.tokenizer == "/elsewhere/tokenizer"
    ))
  ];
in
pkgs.runCommand "strata-module-test" { } ''
  echo ${lib.escapeShellArgs results}
  mkdir -p "$out"
''
