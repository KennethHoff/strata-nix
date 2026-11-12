# strata-nix

> [!WARNING]
> **AI slop.** This flake was written by an AI agent. It has been verified to
> work on the setup below (RX 6600, 8 GB VRAM, 32 GB RAM), but do not expect
> continued support.

It is tuned for one machine: an **AMD RX 6600 with 8 GB of VRAM and 32 GB of
RAM**. The `gfx1030` build target follows from that card. For other
hardware, fork it and adjust.

A Nix flake for [Strata](https://github.com/Niko1221/Strata), the MoE inference
engine with a VRAM/RAM/SSD expert cache, built for AMD GPUs through HIP/ROCm.
It packages the engine and its OpenAI/Anthropic-compatible server, and runs the
server as a NixOS service. x86_64-linux only, since nixpkgs ships ROCm only there.

## Usage

```nix
{
  inputs.strata-nix = {
    url = "github:kennethhoff/strata-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, strata-nix, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        strata-nix.nixosModules.default
        {
          services.strata = {
            enable = true;
            modelName = "my-model";
            tokenizer = "/models/my-model/pack/tokenizer";
            args = [ "--pack" "/models/my-model/pack" "--native" "/models/my-model/model.gguf" ];
          };
        }
      ];
    };
  };
}
```

`systemctl start strata` starts it; set `services.strata.autoStart = true` to
start it at boot. The model, its pack and the engine's arguments are yours to
supply: `strata-iq-pack --gguf model.gguf --out pack` builds a pack from a native
GGUF, and `strata generate --help` lists the arguments.

Outputs:

| Output | What |
| --- | --- |
| `packages.x86_64-linux.strata` (`default`) | `strata` (engine), `strata-server`, `strata-iq-pack` |
| `nixosModules.default` | `services.strata` |
| `overlays.default` | adds `pkgs.strata` |
| `apps.x86_64-linux.update` | bumps `versions.nix` to the newest release |

```bash
nix run github:kennethhoff/strata-nix -- --help   # strata-server
```

## GPU targets

The default build targets `gfx1030`. RDNA2 cards below the RX 6800 run it with
`HSA_OVERRIDE_GFX_VERSION=10.3.0` in `services.strata.environment`. For another
GPU:

```nix
services.strata.package = strata-nix.packages.x86_64-linux.strata.override {
  gpuTargets = [ "gfx1100" ];
};
```

`gyroPromptKernels = false` turns off the Gyro trellis prompt kernels, which
are validated only on gfx1151 and hang an RX 6600 on long prompts.

## Updating

```bash
nix run .#update
```

Strata's CMake fetches llama.cpp's ggml at configure time, which the Nix sandbox
cannot, so `versions.nix` pins that commit too. The updater reads it from the
release's `CMakeLists.txt`, and the build fails if the two drift apart.
