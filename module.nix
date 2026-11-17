# services.strata: Strata's OpenAI/Anthropic-compatible server as a systemd
# service. Importing it also adds pkgs.strata and pkgs.strata-iq-pack, enabled
# or not, so a host can build model packs with pkgs.strata-iq-pack.mkPack,
# and pkgs.strata-vision, the picture reader services.strata.vision runs.
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
# ## Why the mmproj is fetched by default
#
# Every Qwen3.8-Flash-Next quant Strata supports, Gyro's included, reads
# pictures with ISTA-DASLab's mmproj; Strata's setup pins the same file and
# commit. It is a separate download so turning pictures on never changes, and
# so never rebuilds, the model's pack.
#
# ## Why the learned profile is named after the model
#
# The server starts from any saved profile whose layer and expert counts match
# the configured one, so two quants of one model would share a single file.
#
# ## Why DFlash2 needs a folder of its own
#
# The server takes the drafter only from `dflash2/` two levels above the
# `--pack` path, which for a model in the store is the store itself. `dflash2`
# therefore serves the pack through a folder that links the model beside the
# drafter packs. Only `--pack` moves: the tokenizer, `--native` and pictures
# keep the model's own paths.
#
# ## Why the config names the HIP backend
#
# Without `"backend": "hip"` the server takes the card for an NVIDIA one: it
# reports no GPU readings and hands the engine CUDA-tuned GDN settings
# (STRATA_GDN_TC, STRATA_GDN_CONVL2). The package is a HIP build only.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.strata;
  vision = cfg.vision;
  nativeGguf = if cfg.nativeGguf != null then cfg.nativeGguf else "${cfg.model}/model.gguf";
  stateDir = "/var/lib/strata";
  packDir =
    if cfg.dflash2 == null then
      "${cfg.model}/pack"
    else
      "${
        pkgs.runCommand "strata-model-with-dflash2" { } ''
          mkdir $out
          ln -s ${cfg.model} $out/model
          ln -s ${cfg.dflash2} $out/dflash2
        ''
      }/model/pack";
  engineConfig = pkgs.writeText "strata.json" (builtins.toJSON cfg.engineSettings);
  engineSettings = {
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
    backend = "hip";
  }
  // lib.optionalAttrs (cfg.allowedHosts != [ ]) {
    allowed_hosts = cfg.allowedHosts;
  }
  // lib.optionalAttrs vision.enable {
    vision = {
      exe = lib.getExe vision.package;
      mmproj = toString vision.mmproj;
      inherit (vision) model;
      gpu = false;
      max_tokens = vision.maxTokens;
    }
    // lib.optionalAttrs (vision.threads != null) { inherit (vision) threads; };
  }
  // lib.optionalAttrs cfg.learnExpertProfile {
    expert_profile_save = "${stateDir}/expert-profile-${cfg.modelName}.bin";
  }
  // lib.optionalAttrs (cfg.drafting != null) { inherit (cfg) drafting; }
  // lib.optionalAttrs (cfg.userArgs != [ ]) { user_args = cfg.userArgs; };
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
    nativeGguf = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/srv/strata/m/Model-IQ2_XS-00001-of-00002.gguf";
      description = ''
        The GGUF {option}`model` passes to `--native` and pictures are read
        from, instead of `''${model}/model.gguf`. A split model needs its first
        shard under its own name: Strata finds the other shards by rewriting
        the `-00001-of-0000N` part, and refuses a shard opened under another
        name ("is shard 1 of N, but it was opened as a whole model").
      '';
    };
    pleGguf = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/srv/strata/Qwen3.8-Flash-Next-PLE-IQ4_NL.gguf";
      description = ''
        A standalone n-gram (PLE) table for a `-noPLE` model. {option}`model`
        then also passes `--ple-gguf` with it and `--native-dense-gguf` with
        the native GGUF: without the second, the engine reads the table as a
        weight shard and stops with "missing qwen4exp.block_count". Leave it
        unset for a model that carries its table, a split one included.
      '';
    };
    drafting = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "auto"
          "mtp"
          "dflash2"
          "off"
        ]
      );
      default = null;
      description = ''
        Which drafter guesses tokens ahead: the model's own MTP layer, the
        DFlash2 draft model, or none. Unset leaves the choice to the server,
        which takes the MTP unless it finds DFlash2 packs and its own table
        prefers them for the card and model. The server rewrites the
        drafter's options in {option}`args` to match at every start, so
        `--draft dflash2` there has no effect without this.
      '';
    };
    userArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--spec"
        "8"
        "--draft-conf"
        "0.7"
      ];
      description = ''
        Engine options the server keeps over the ones it generates. With
        `drafting = "dflash2"` it sets the verify window and confidence
        itself; the ones given here win.
      '';
    };
    dflash2 = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.package lib.types.str);
      default = null;
      example = lib.literalExpression "pkgs.strata-dflash2";
      description = ''
        A directory holding the DFlash2 drafter packs, as `pkgs.strata-dflash2`
        builds them. With {option}`model` set, the model is then served from a
        folder that links both, since the server only looks for the packs in
        `dflash2/` two levels above `--pack`.
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
    vision = {
      enable = lib.mkEnableOption ''
        pictures: OpenAI image_url parts and Anthropic image blocks, read on
        the CPU by strata-vision and handed to the engine as embeddings
      '';
      package = lib.mkPackageOption pkgs "strata-vision" { };
      mmproj = lib.mkOption {
        type = lib.types.either lib.types.package lib.types.str;
        default = pkgs.fetchurl {
          name = "mmproj-Qwen3.8-Flash-Next-BF16.gguf";
          url = "https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/resolve/ed59f92082b1e93c0e96d60a8b11aab089b52f09/mmproj-Qwen3.8-Flash-Next-BF16.gguf";
          hash = "sha256-sagiWXAoFqUzDXvXYHzZZ2sReA55/3NIwhED/zzkm9A=";
        };
        defaultText = lib.literalMD "ISTA-DASLab's `mmproj-Qwen3.8-Flash-Next-BF16.gguf` (0.9 GB), as Strata's setup pins it";
        description = ''
          The model's vision encoder and projector. The default fits every
          Qwen3.8-Flash-Next quant, Gyro's included; Swift 1.5 has its own.
        '';
      };
      model = lib.mkOption {
        type = lib.types.str;
        description = ''
          The text model's GGUF (its first shard), which the reader opens for
          the vocabulary only. Defaults to `''${model}/model.gguf` when
          {option}`services.strata.model` is set.
        '';
      };
      maxTokens = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 300;
        description = ''
          Most image tokens one picture becomes; 0 for no limit. 300 is
          Strata's default for the CPU reader.
        '';
      };
      threads = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "CPU threads the reader uses; null leaves it to the reader.";
      };
    };
    engineSettings = lib.mkOption {
      type = lib.types.attrs;
      internal = true;
      readOnly = true;
      description = "The JSON config strata-server starts the engine from, as an attribute set.";
    };
    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Environment of the server and engine.";
    };
  };

  config = lib.mkMerge [
    { services.strata = { inherit engineSettings; }; }
    { nixpkgs.overlays = [ (import ./overlay.nix) ]; }
    (lib.mkIf (cfg.model != null) {
      services.strata = {
        tokenizer = lib.mkDefault "${cfg.model}/pack/tokenizer";
        vision.model = lib.mkDefault nativeGguf;
        args = lib.mkBefore (
          [
            "--pack"
            packDir
            "--native"
            nativeGguf
          ]
          ++ lib.optionals (cfg.pleGguf != null) [
            "--ple-gguf"
            cfg.pleGguf
            "--native-dense-gguf"
            nativeGguf
          ]
        );
      };
    })
    (lib.mkIf vision.enable { services.strata.args = lib.mkAfter [ "--vision" ]; })
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
