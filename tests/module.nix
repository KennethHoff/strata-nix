# services.strata turns its options into a strata.service that runs the
# server on the configured address with an engine config holding them.
# Evaluation only: the package's path is compared without building it.
{
  pkgs,
  self,
  nixpkgs,
  ...
}:
let
  inherit (pkgs) lib;
  system = nixpkgs.lib.nixosSystem {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = [
      self.nixosModules.default
      {
        boot.isContainer = true;
        system.stateVersion = "26.05";
        services.strata = {
          enable = true;
          host = "0.0.0.0";
          port = 9000;
          modelName = "test-model";
          tokenizer = "/models/tokenizer";
          args = [
            "--pack"
            "/models/pack"
          ];
        };
      }
    ];
  };
  service = system.config.systemd.services.strata;
  execStart = builtins.unsafeDiscardStringContext service.serviceConfig.ExecStart;
  strata = builtins.unsafeDiscardStringContext (toString system.config.services.strata.package);
  expect = name: ok: if ok then name else throw "strata module check failed: ${name}";
  results = [
    (expect "runs strata-server" (lib.hasPrefix "${strata}/bin/strata-server --config " execStart))
    (expect "binds the configured address" (lib.hasSuffix " --host 0.0.0.0 --port 9000" execStart))
    (expect "not started at boot by default" (service.wantedBy == [ ]))
    (expect "swap off" (service.serviceConfig.MemorySwapMax == 0))
  ];
in
pkgs.runCommand "strata-module-test" { } ''
  echo ${lib.escapeShellArgs results}
  mkdir -p "$out"
''
