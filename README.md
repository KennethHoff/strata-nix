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

## 1. Prerequisites

- **NixOS on x86_64-linux** with flakes enabled. nixpkgs ships ROCm only for
  x86_64-linux.
- **An AMD GPU the build targets.** The default is `gfx1030`, and RDNA2 cards
  below the RX 6800 (gfx1031/gfx1032) run it through an override (see step 2).
  Other GPUs need a rebuild, see [GPU targets](#gpu-targets).
- **The `amdgpu` kernel driver**, which NixOS loads by default on AMD GPUs.
  The engine reaches the GPU through `/dev/kfd` and `/dev/dri`; the service
  joins the `render` and `video` groups for that.
- **RAM and disk for the model.** The example model is a 58 GB file and its
  pack about 1.5 GB more; with 32 GB of RAM the engine keeps 20 GiB of experts
  in RAM and reads the rest from disk on every use, so put the model on the
  fastest SSD you have. With step 3a that is wherever `/nix/store` lives; step
  3b lets you pick the drive.
- **Time for the first build.** No binary cache carries Strata, so the first
  switch compiles the HIP engine locally; ROCm itself comes from
  cache.nixos.org.

## 2. Installing and wiring up the Strata server

Add the flake and import its module. The module also adds `pkgs.strata` and
`pkgs.strata-iq-pack`:

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
        ./strata.nix
      ];
    };
  };
}
```

Then configure the server in `strata.nix`. These are the settings this flake is
tuned for (RX 6600, 8 GB VRAM, 32 GB RAM); `model` comes from step 3a or 3b:

```nix
{ config, pkgs, ... }:
{
  services.strata = {
    enable = true;
    model = …; # step 3a or 3b
    modelName = "gyro-s";
    maxContext = 131072;
    # Changing the thinking level mid-session keeps the cached conversation.
    effortPosition = "end";
    learnExpertProfile = true;
    environment = {
      # gfx1032 runs the gfx1030 build.
      HSA_OVERRIDE_GFX_VERSION = "10.3.0";
      # Free RAM the RAM budget below must leave at start.
      STRATA_RESIDENT_HEADROOM_GIB = "4";
      # Hot experts missing from RAM replace unused ones before each decode window.
      STRATA_RAM_ADAPT = "1";
      # rocBLAS on gfx1030 is tuned only for FP16 output; FP16 prompts read faster.
      STRATA_HIP_PROMPT_F16 = "1";
      # Strata's workaround for a gfx1030 hang during decode's expert swaps.
      STRATA_HIP_ADAPT_KERNEL_COPY = "1";
    };
    # `model` puts --pack and --native in front of these.
    args = [
      "--expert-profile" "${config.services.strata.package}/share/strata/data/expert-profile.bin"
      "--expert-cache" "auto"
      "--prefill" "auto"
      "--kv" "int8"
      # Only this many tokens of K/V stay in VRAM; the rest lives in RAM and
      # the freed VRAM goes to the expert cache.
      "--kv-resident" "20480"
      # The hottest 20 GiB of experts stay in RAM; more OOMs long prefills.
      "--resident-budget-gib" "20"
      # VRAM left for the desktop.
      "--vram-reserve-mib" "900"
      # Native packs need a verify window of 2+.
      "--spec" "2"
    ];
  };
}
```

The server isn't started at boot, since its expert cache fills the GPU for as
long as it runs: `systemctl start strata` starts it, and
`services.strata.autoStart = true` starts it at boot. It listens on
`127.0.0.1:8080` (`services.strata.host` and `port`) with the OpenAI API under
`/v1` and the Anthropic API at `/v1/messages`. `strata generate --help` lists
the engine's arguments.

## 3a. Automatic model download

`pkgs.strata-iq-pack.mkPack` takes a GGUF (usually a `fetchurl`) and builds
the pack Strata reads, in the layout `services.strata.model` expects. For Qwen3.8-Flash-Next Gyro-S (27.6 GiB of weights, a 58 GB file with its
n-gram table):

```nix
# strata.nix
{ pkgs, ... }:
{
  services.strata = {
    enable = true;
    model = pkgs.strata-iq-pack.mkPack {
      name = "strata-gyro-s";
      gguf = pkgs.fetchurl {
        url = "https://huggingface.co/agentionai/Qwen3.8-Flash-Next-Gyro-GGUF/resolve/257c95704b87e99d12e4b1cbd65794837009d587/Qwen3.8-Flash-Next-Gyro-S-TQ1_0.gguf";
        hash = "sha256-xuobCMoxL5kJWydYi6NZdrU/lIJo5/ked2GSaqAdnIc=";
      };
      packArgs = [ "--compat-bf16" ];
    };
    modelName = "gyro-s";
    # …the rest of step 2
  };
}
```

The next switch downloads the GGUF into the Nix store and packs it. The pack
depends only on Strata's source and ggml pin, so rebuilding the engine (another
GPU target, the Gyro kernels) doesn't re-pack the model. Garbage collection
removes the GGUF only when no system generation refers to it.

Avoid `gguf = ./my-model.gguf` for a file you already have: Nix would copy the
whole file into the store. Use step 3b instead.

## 3b. Manual model download

To keep the model outside the Nix store, download it and build its pack once
by hand:

```bash
sudo mkdir -p /srv/strata/gyro-s
sudo curl -L -o /srv/strata/gyro-s/model.gguf \
  https://huggingface.co/agentionai/Qwen3.8-Flash-Next-Gyro-GGUF/resolve/257c95704b87e99d12e4b1cbd65794837009d587/Qwen3.8-Flash-Next-Gyro-S-TQ1_0.gguf
sudo nix run github:kennethhoff/strata-nix#strata-iq-pack -- \
  --gguf /srv/strata/gyro-s/model.gguf --out /srv/strata/gyro-s/pack --compat-bf16
sudo chmod -R a+rX /srv/strata
```

Then point step 2 at that directory:

```nix
# strata.nix
{ ... }:
{
  services.strata = {
    enable = true;
    model = "/srv/strata/gyro-s";
    modelName = "gyro-s";
    # …the rest of step 2
  };
}
```

To lay the files out differently, leave `model` unset and give the paths
yourself (see [`model`](#model)):

```nix
services.strata = {
  tokenizer = "/srv/strata/gyro-s/pack/tokenizer";
  args = [
    "--pack" "/srv/strata/gyro-s/pack"
    "--native" "/data/gguf/gyro-s.gguf"
    # …the tuning arguments from step 2
  ];
};
```

The service runs as a dynamic user with `ProtectSystem=strict`,
`ProtectHome=read-only` and a private `/tmp`, so:

- Keep the files outside `/tmp` and anything the user can't read. A home
  directory works only if every directory on the path is world-searchable;
  `/srv` or `/var/lib` is simpler.
- Make them world-readable, as above: the dynamic user owns nothing outside
  `/var/lib/strata`.
- Re-run `strata-iq-pack` after a Strata update that changes the pack format;
  a Nix-built pack would do that by itself.

`--compat-bf16` is what the Gyro-S example packs with; `strata-iq-pack --help`
says when it applies and lists the other options.

## 4. Checking it works

```bash
sudo systemctl start strata
curl -s http://127.0.0.1:8080/health
```

The first start reads the model and fills the expert cache, which takes
minutes; `/health` reports `"loaded": true` once it's ready. Then send one
request:

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "gyro-s", "messages": [{"role": "user", "content": "Say hi"}]}'
```

`journalctl -u strata -f` shows the load as it happens.

## 5. Connecting a client

| API | Base URL |
| --- | --- |
| OpenAI (chat completions, responses) | `http://127.0.0.1:8080/v1` |
| Anthropic (messages) | `http://127.0.0.1:8080` (`/v1/messages`) |

The model id is `services.strata.modelName`. Without an API key the server
accepts any key a client insists on sending. To require one, set
`STRATA_API_KEY`:

```nix
services.strata.environment.STRATA_API_KEY = "my-key";
```

That works, but it puts the key in the Nix store, which every user on the
machine can read. Keeping it out is better: put `STRATA_API_KEY=…` in a file
only root can read (from sops-nix or agenix, say) and hand that to the unit:

```nix
systemd.services.strata.serviceConfig.EnvironmentFile = "/run/secrets/strata.env";
```

Clients then send it as `Authorization: Bearer …` or `x-api-key: …`.

## Remote access

The server binds `127.0.0.1`. To reach it from other machines, either bind
another address and open the port:

```nix
services.strata.host = "0.0.0.0";
networking.firewall.allowedTCPPorts = [ 8080 ];
```

or keep it on loopback behind a reverse proxy. Either way, without an API key
Strata answers a `Host` header it doesn't know with 403, which guards against
DNS rebinding. IP addresses and `localhost` always pass; list every name
clients use, such as the proxy's:

```nix
services.strata.allowedHosts = [ "strata.example.com" ];
```

Anything that reaches the port can use the model, so set an API key (step 5)
before exposing it beyond a trusted network.

## Troubleshooting

- **Logs:** `journalctl -u strata` for the server, `/var/lib/strata/strata.log`
  for the engine.
- **The GPU hangs partway through a long prompt:** the Gyro prompt kernels are
  the usual cause on RDNA2; they're off by default, so check that an override
  didn't turn them back on.
- **The GPU hangs while decoding:** keep `STRATA_HIP_ADAPT_KERNEL_COPY = "1"`
  on gfx1030-class cards.
- **The engine finds no kernel for the GPU:** an RDNA2 card below the RX 6800
  needs `HSA_OVERRIDE_GFX_VERSION = "10.3.0"`; anything else needs its own
  [GPU target](#gpu-targets).
- **Out of memory during a long prompt:** lower `--resident-budget-gib` or raise
  `STRATA_RESIDENT_HEADROOM_GIB`, so the prompt's buffers fit beside the RAM
  experts.
- **403 from a client:** its `Host` name is missing from
  `services.strata.allowedHosts` (see [Remote access](#remote-access)).
- **Games or the desktop stutter:** the expert cache holds VRAM for as long as
  the server runs; `systemctl stop strata` gives it back.

## GPU targets

The default build targets `gfx1030`. RDNA2 cards below the RX 6800 run it with
`HSA_OVERRIDE_GFX_VERSION=10.3.0` in `services.strata.environment`. For another
GPU:

```nix
services.strata.package = pkgs.strata.override {
  gpuTargets = [ "gfx1100" ];
};
```

The Gyro trellis prompt kernels are off, since they hang an RX 6600 partway
through long prompts. Upstream validates them only on gfx1151; turn them back on
there with `.override { gyroPromptKernels = true; }`.

## Flake outputs

| Output | What |
| --- | --- |
| `packages.x86_64-linux.strata` (`default`) | `strata` (engine), `strata-server`, `strata-iq-pack` |
| `packages.x86_64-linux.strata-iq-pack` | `strata-iq-pack` alone, without ROCm; `.mkPack` builds a model's pack |
| `nixosModules.default` | `services.strata` |
| `overlays.default` | adds `pkgs.strata` and `pkgs.strata-iq-pack` (the NixOS module applies it itself) |
| `apps.x86_64-linux.update` | bumps `versions.nix` to the newest release |

```bash
nix run github:kennethhoff/strata-nix -- --help   # strata-server
```

## Updating

```bash
nix run .#update
```

Strata's CMake fetches llama.cpp's ggml at configure time, which the Nix sandbox
cannot, so `versions.nix` pins that commit too. The updater reads it from the
release's `CMakeLists.txt`, and the build fails if the two drift apart.

## Available options

All under `services.strata`:

| Option | Default | What it does |
| --- | --- | --- |
| `enable` | `false` | Runs the server as `strata.service`. |
| `package` | `pkgs.strata` | The engine and server; `.override { gpuTargets = …; gyroPromptKernels = …; }` rebuilds it. |
| `autoStart` | `false` | Starts the server at boot; otherwise `systemctl start strata`. |
| `host` | `"127.0.0.1"` | Address the API binds to. |
| `port` | `8080` | Port of the OpenAI (`/v1`) and Anthropic (`/v1/messages`) APIs. |
| `allowedHosts` | `[ ]` | Host names the API answers to besides its address and `localhost`. |
| `model` | `null` | A directory with `model.gguf` and `pack/`; see below. |
| `modelName` | (required) | The model id the API reports. |
| `tokenizer` | from `model` | The pack's tokenizer directory; required when `model` is unset. |
| `maxContext` | `65536` | Longest context the engine accepts, in tokens. |
| `args` | `[ ]` | Engine arguments (`strata generate --help`). |
| `effortPosition` | `"start"` | Where a request's reasoning effort goes in the prompt: `"start"` (Strata's default) or `"end"`, which keeps the cached conversation when the effort changes. |
| `learnExpertProfile` | `false` | Saves the expert ranking learned from traffic to `/var/lib/strata`; the next start uses it instead of `--expert-profile`. |
| `environment` | `{ }` | Environment of the server and engine, e.g. `HSA_OVERRIDE_GFX_VERSION`. |

### `model`

Optional. Setting it is shorthand for three settings you can also give by hand:

```nix
services.strata.model = "/srv/strata/gyro-s";
```

is the same as

```nix
services.strata = {
  tokenizer = "/srv/strata/gyro-s/pack/tokenizer";
  args = [
    "--pack" "/srv/strata/gyro-s/pack"
    "--native" "/srv/strata/gyro-s/model.gguf"
    # …followed by your own args
  ];
};
```

The tokenizer is only a default, so setting `tokenizer` yourself wins; the two
arguments always come first in `args`. With `model` unset, `tokenizer` and the
`--pack`/`--native` arguments are yours to give, for a pack without a native
GGUF or files laid out another way.

## What optimizations have we done

Everything below was measured on the machine this flake targets: RX 6600
(gfx1032, 8 GB, PCIe 4.0 x8), Ryzen 9 3900X, 32 GB RAM, an NVMe SSD, three
monitors, serving abliterated Gyro-S. Most figures are one run each, and two
identical runs differed by up to 3%, so treat gains inside that as noise.

These are performance benchmarks only. No intelligence or answer-quality
benchmark has been run on this setup: the only checks were that benchmark
answers came out right (a record looked up from a 9K-token list, and one from a
107K-token context). Quality figures for Gyro-S itself are its author's. Some
kept settings trade a little precision for speed (FP16 prompt math) or place
the reasoning effort differently (`effortPosition = "end"`), and their effect on
answers is unmeasured.

### The result

Same prompts, before the last round of tuning (the hang and out-of-memory fixes
below already in) against the settings in step 2:

| | Before | After |
| --- | --- | --- |
| 25K-token prompt | 164 s (163 tok/s) | 104 s (258 tok/s) |
| 9.2K / 9.4K-token prompt | 53 s / 53 s | 36 s / 37 s |
| Decode (16 prompts) | 18.9 tok/s | 20.2 tok/s |
| Fixed wait per request | 3.1 s | 2.9 s |
| Experts cached in VRAM | 1,526 | 1,956 |
| Prompt chunk | 2,816 tokens | 3,328 tokens |
| Context cap | 65,536 | 131,072 |
| RAM free with Strata loaded | 5.1-6.7 GiB | 4.2-4.7 GiB |

These are synthetic benchmarks: long, repetitive lists of numbered records
with one question at the end, which read faster than real conversations. Don't
expect 258 tok/s in practice. Over seven real agent requests, prompts read at
about 127 tok/s, half the benchmark rate. Use the table to compare settings,
not to predict real speed.

Prompt reading is what matters most: in those real requests about 89% of the
engine's time went to reading prompts and 11% to writing answers.

### Kept

| Setting | Why | Measured |
| --- | --- | --- |
| `gfx1030` build + `HSA_OVERRIDE_GFX_VERSION=10.3.0` | nixpkgs' rocBLAS has no gfx1032 kernels; a native build would mean rebuilding rocBLAS. | Builds and runs; Strata's own tests pass. |
| Gyro prompt kernels off (`gyroPromptKernels = false`) | With them the GPU hung partway through a 7.4K-token prompt, also with the workarounds below. | Without: 4 of 4 fresh 7.4K prompts read cleanly at 157-160 tok/s. |
| `STRATA_HIP_ADAPT_KERNEL_COPY=1` | Upstream's workaround for a GPU hang during decode's expert swaps on RDNA2. | Stopped a decode hang seen once without it; cost not measured. |
| `STRATA_HIP_PROMPT_F16=1` | rocBLAS on gfx1030 is tuned only for FP16-in, FP16-out products. | 9.2K prompt 68 s → 48 s, 9.4K 71 s → 36 s, same session, answers still correct. |
| `--resident-budget-gib 20` | Unbounded, the engine put 24 GiB of experts in RAM and a 25K prompt got OOM-killed. | No more OOM kills; speed not compared. |
| `STRATA_RESIDENT_HEADROOM_GIB=4` (was 6) | The RAM tier is cut to free RAM at start minus this; at 6 the 20 GiB budget came out at 17.7 GiB. | A bigger tier on a given day; how big depends on what the desktop holds at start. |
| `STRATA_RAM_ADAPT=1` + `learnExpertProfile` | Experts missing from RAM are read from disk on every use; hot ones now replace unused ones. | 2,883 experts swapped in during one session; decode gain not separable from other changes. |
| `--kv-resident 20480` with a 131K cap | The whole K/V was reserved in VRAM, taking room from the expert cache and the prompt chunk. | Raised the cap from 65K to 131K while prompts got faster (table above). A 107K-token conversation answered at 24 tok/s. |
| `effortPosition = "end"` | Changing the thinking level rewrote the first system message, so the whole conversation was read again. | Not measured here. |
| `--spec 2`, no draft head | Native packs require a verify window of 2+. | See the draft head below. |
| `MemorySwapMax = 0` on the unit | A swapped-out expert turns a memory read into a disk read. | With swap allowed, a 25K prompt stalled for 2+ minutes with 15 GiB in swap. |

### Tried and dropped

| Tried | Result |
| --- | --- |
| MTP draft head (`--mtp`, `--spec 4`) | Decode 20.2 → 23.3 tok/s, but its 1 GiB of VRAM cut the prompt chunk from 3,328 to 1,280 tokens: a 25K prompt read at 184 instead of 258 tok/s, and every request waited 1.7 s longer. Only replies over about 150 tokens come out ahead. |
| `--kv-resident 8192` | More experts cached, but a 9.2K prompt took 82 s instead of 54 s. |
| 262K context | 9.2K prompt 54 s → 84 s, since the cap's VRAM is reserved at start. |
| 131K with `--kv q4_0`, before `--kv-resident` | VRAM expert cache 1.52 → 0.58 GiB, prompts down to 69 tok/s. |
| Letting the unit swap, headroom 10 GiB | Thrashing (above); the headroom does nothing without a budget flag. |
| `--prefill-head-alias` | Crashed the engine on every second request (a known upstream bug). |
| `STRATA_MTP_ROOM_MIN=1024` | 9.2K prompt 54 s → 68 s. |
| `--mtp-q4 all` | Fewer experts cached and slower prompts, not more VRAM. |
| `spec_min_p`, `pcie_frac` sweeps | Flat: the best value was within the 3% noise. |
| `STRATA_SH_STREAM=1`, adaptive cache tuning | Within noise. |
| llama.cpp with a dense 27B | About 3 tok/s, since over half the model ran on the CPU. |

### Not tried yet

- `STRATA_ROUTE_TAIL_SKIP=7`: upstream reports +10-20% decode on 12-16 GB
  cards, at a small cost in answer quality.
- `--adapt-swaps 0`: stopped "no progress for 60 s" prompt stalls on a gfx1031
  card in an upstream issue, at the cost of cache slots.
- Enabling the RAM's XMP/DOCP profile: the DIMMs ran at 2666 MT/s though
  rated 3200.
- More RAM: room for `--kv-grow`, the PLE table in RAM and a larger quant.
