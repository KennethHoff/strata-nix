# services.strata: Strata's OpenAI/Anthropic-compatible server as a systemd
# service. Importing it also adds pkgs.strata and pkgs.strata-iq-pack, enabled
# or not, so a host can build model packs with pkgs.strata-iq-pack.mkPack.
#
# ## Why it is not started at boot by default
#
# The engine fills the GPU with its expert cache for as long as it runs, so on
# a desktop it starves games. `autoStart = false` leaves it to
# `systemctl start strata`.
#
# ## Why swap is off for it
#
# Its RAM tier holds the experts that miss VRAM; a swapped-out page turns a
# memory read on the token path into a disk read.
#
# ## Why the learned profile is named after the model
#
# The server starts from any saved profile whose layer and expert counts match
# the configured one, so two quants of one model would share a single file.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.strata;
  stateDir = "/var/lib/strata";
  engineConfig = pkgs.writeText "strata.json" (
    builtins.toJSON (
      {
        exe = lib.getExe' cfg.package "strata";
        args = cfg.args ++ [
          "--max-context"
          (toString cfg.maxContext)
        ];
        inherit (cfg) tokenizer;
        cwd = stateDir;
        log = "${stateDir}/strata.log";
        model_name = cfg.modelName;
        inherit (cfg) host port;
        effort_position = cfg.effortPosition;
      }
      // lib.optionalAttrs (cfg.allowedHosts != [ ]) {
        allowed_hosts = cfg.allowedHosts;
      }
      // lib.optionalAttrs cfg.learnExpertProfile {
        expert_profile_save = "${stateDir}/expert-profile-${cfg.modelName}.bin";
      }
    )
  );
in
{
  options.services.strata = {
    enable = lib.mkEnableOption "the Strata inference server";
    package = lib.mkPackageOption pkgs "strata" { };
    autoStart = lib.mkEnableOption "starting Strata at boot";
    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the API binds to.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port of the OpenAI (/v1) and Anthropic (/v1/messages) APIs.";
    };
    allowedHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Host names the API answers to besides its bind address and localhost.
        With no API key Strata answers any other Host header with 403 (DNS
        rebinding protection), so a name a reverse proxy forwards goes here.
      '';
    };
    modelName = lib.mkOption {
      type = lib.types.str;
      description = "Model id the API reports.";
    };
    model = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.package lib.types.str);
      default = null;
      example = lib.literalExpression ''"/srv/strata/gyro-s"'';
      description = ''
        A directory holding the model as `model.gguf` and its pack as `pack/`,
        as `pkgs.strata-iq-pack.mkPack` builds it. When set, {option}`tokenizer`
        defaults to `''${model}/pack/tokenizer` and {option}`args` starts with
        `--pack ''${model}/pack --native ''${model}/model.gguf`. Leave it unset
        to give those yourself.
      '';
    };
    tokenizer = lib.mkOption {
      type = lib.types.str;
      description = "The pack's tokenizer directory.";
    };
    maxContext = lib.mkOption {
      type = lib.types.ints.positive;
      default = 65536;
      description = "Longest context the engine accepts, in tokens.";
    };
    args = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Engine arguments (`strata --help`).";
    };
    effortPosition = lib.mkOption {
      type = lib.types.enum [
        "start"
        "end"
      ];
      default = "start";
      description = ''
        Where a request's reasoning effort goes in the prompt. `start` is
        Strata's default, the top of the first system message, where changing
        the effort changes the prompt's first tokens and the whole conversation
        is read again. `end` puts a non-default effort in a short system turn
        before the answer, which keeps the cached conversation.
      '';
    };
    learnExpertProfile = lib.mkEnableOption ''
      saving the expert ranking the engine learns from traffic, which the next
      start uses in place of the `--expert-profile` in {option}`args`
    '';
    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Environment of the server and engine.";
    };
  };

  config = lib.mkMerge [
    { nixpkgs.overlays = [ (import ./overlay.nix) ]; }
    (lib.mkIf (cfg.model != null) {
      services.strata = {
        tokenizer = lib.mkDefault "${cfg.model}/pack/tokenizer";
        args = lib.mkBefore [
          "--pack"
          "${cfg.model}/pack"
          "--native"
          "${cfg.model}/model.gguf"
        ];
      };
    })
    (lib.mkIf cfg.enable {
      systemd.services.strata = {
        description = "Strata inference server";
        after = [ "network.target" ];
        wantedBy = lib.mkIf cfg.autoStart [ "multi-user.target" ];
        inherit (cfg) environment;
        serviceConfig = {
          ExecStart = lib.escapeShellArgs [
            (lib.getExe cfg.package)
            "--config"
            engineConfig
            "--host"
            cfg.host
            "--port"
            (toString cfg.port)
          ];
          DynamicUser = true;
          StateDirectory = "strata";
          WorkingDirectory = stateDir;
          SupplementaryGroups = [
            "render"
            "video"
          ];
          LimitMEMLOCK = "infinity";
          MemorySwapMax = 0;
          Restart = "on-failure";
          RestartSec = 30;
        };
      };
    })
  ];
}
