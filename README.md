# strata-nix

> [!WARNING]
> **AI slop.** This flake was written by an AI agent. It has been verified to
> work on the setup below (RX 6600, 8 GB VRAM, 32 GB RAM), but do not expect
> continued support.

It is tuned for that one machine. The `gfx1030` build target follows from that
card. For other hardware, fork it and adjust.

A Nix flake for [Strata](https://github.com/Niko1221/Strata), the MoE inference
engine with a VRAM/RAM/SSD expert cache, built for AMD GPUs through HIP/ROCm.
It packages the engine and its OpenAI/Anthropic-compatible server, and runs the
server as a NixOS service. x86_64-linux only.

## 1. Prerequisites

- **NixOS on x86_64-linux** with flakes enabled. nixpkgs ships ROCm only for
  x86_64-linux.
- **An AMD GPU the build targets.** The default is `gfx1030`, and RDNA2 cards
  below the RX 6800 (gfx1031/gfx1032) run it through an override (see step 2).
  Other GPUs need a rebuild, see [GPU targets](#gpu-targets).
- **The `amdgpu` kernel driver**, which NixOS loads by default on AMD GPUs.
  The engine reaches the GPU through `/dev/kfd` and `/dev/dri`; the service
  joins the `render` and `video` groups for that.
- **Memory and disk for the model.** The example model, Gyro-S, is a 58 GB file
  and its pack adds about 1.5 GB. Upstream says it needs 27.6 GB of VRAM and
  RAM together; the rest of the file, its n-gram table, stays on the SSD. Here
  the RAM tier is capped at 20 GiB (`--resident-budget-gib`) and shrinks to the
  free RAM at start minus `STRATA_RESIDENT_HEADROOM_GIB` (set in step 2), and experts beyond VRAM and RAM
  are read from disk on every use, so put the model on the fastest SSD you
  have. With step 3a that is wherever `/nix/store` lives; step
  3b lets you pick the drive.
- **Time for the first build.** No binary cache carries Strata, so the first
  switch compiles the HIP engine locally; ROCm itself comes from
  cache.nixos.org.

## 2. Installing and wiring up the Strata server

Add the flake and import its module. These are additions to your existing
flake, whose `nixpkgs` input is your own; the module also adds `pkgs.strata`
and `pkgs.strata-iq-pack`:

```nix
{
  # …your existing inputs, including nixpkgs
  inputs.strata-nix = {
    url = "github:kennethhoff/strata-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # …your existing outputs; the host's modules list gains these two entries
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

This was tested on nixos-unstable. With the `follows` line the build uses your
nixpkgs, so a different one (a stable release, say) means a different ROCm,
which may not be in cache.nixos.org.

Then configure the server in `strata.nix` (if your flake is a git repo, run
`git add strata.nix`, or the flake won't see it). These are the settings this
flake is tuned for. Replace the `model` line with the one from step 3a or 3b;
it throws until you do:

```nix
{ config, pkgs, ... }:
{
  services.strata = {
    enable = true;
    model = throw "replace this line with the model line from step 3a or 3b";
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
`/v1` and the Anthropic API at `/v1/messages`. To list the engine's arguments
with the same build the service runs, from your flake's directory:

```bash
nix shell .#nixosConfigurations.my-host.config.services.strata.package -c strata --help
```

## 3a. Automatic model download

`pkgs.strata-iq-pack.mkPack` takes a GGUF (usually a `fetchurl`) and builds
the pack Strata reads, in the layout `services.strata.model` expects. For Qwen3.8-Flash-Next Gyro-S, put this in `strata.nix` in place of
step 2's `model` line. The 58 GB file is 27.6 GB of weights Strata keeps in VRAM
and RAM plus Gyro's n-gram table (PLE, per-layer embeddings), which Strata
reads from the SSD as needed:

```nix
# strata.nix: the `model` line replaces step 2's
{ pkgs, ... }:
{
  services.strata = {
    # …enable, modelName and the rest stay as in step 2
    model = pkgs.strata-iq-pack.mkPack {
      name = "strata-gyro-s";
      gguf = pkgs.fetchurl {
        url = "https://huggingface.co/agentionai/Qwen3.8-Flash-Next-Gyro-GGUF/resolve/257c95704b87e99d12e4b1cbd65794837009d587/Qwen3.8-Flash-Next-Gyro-S-TQ1_0.gguf";
        hash = "sha256-xuobCMoxL5kJWydYi6NZdrU/lIJo5/ked2GSaqAdnIc=";
      };
      packArgs = [ "--compat-bf16" ];
    };
  };
}
```

The result is the GGUF (linked from the Nix store, not copied) plus `pack/`.
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
sudo install -d -o "$USER" /srv/strata/gyro-s
curl -fL -C - -o /srv/strata/gyro-s/model.gguf \
  https://huggingface.co/agentionai/Qwen3.8-Flash-Next-Gyro-GGUF/resolve/257c95704b87e99d12e4b1cbd65794837009d587/Qwen3.8-Flash-Next-Gyro-S-TQ1_0.gguf
echo "c6ea1b08ca312f99095b27588ba35976b53f948268e7f91e7761926aa01d9c87  /srv/strata/gyro-s/model.gguf" | sha256sum -c
nix run .#nixosConfigurations.my-host.pkgs.strata-iq-pack -- \
  --gguf /srv/strata/gyro-s/model.gguf --out /srv/strata/gyro-s/pack --compat-bf16
chmod -R a+rX /srv/strata/gyro-s
```

The directory is owned by you, so nothing but `install` needs `sudo`. Run the
`nix run` from your flake's directory, with `my-host` as in step 2; it uses the
Strata your `flake.lock` pins, so the pack matches the server and works before
the first switch. `-f` makes a failed download an error instead of saving an
error page, `-C -` resumes an interrupted one, and `sha256sum -c` must print
`OK`. Then point step
2 at that directory by replacing its `model` line:

```nix
# strata.nix: the `model` line replaces step 2's
{ ... }:
{
  services.strata = {
    # …enable, modelName and the rest stay as in step 2
    model = "/srv/strata/gyro-s";
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
    # …the rest of step 2's args
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

`--compat-bf16` is what the Gyro-S example packs with;
the same `nix run` with `--help` says when it applies and lists the other
options.

## 4. Checking it works

```bash
sudo nixos-rebuild switch --flake .#my-host   # the host name from step 2
sudo systemctl start strata
journalctl -u strata -f   # the load, as it happens
curl -sS http://127.0.0.1:8080/health
```

With step 3a the switch first downloads the GGUF and builds the engine and the
pack. The first start reads the model and fills the expert cache, which takes
minutes; until then `curl` prints nothing or `connection refused`, and
`/health` reports `"loaded": true` once it's ready. Then send one request:

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "gyro-s", "messages": [{"role": "user", "content": "Say hi"}]}'
```

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
  `services.strata.allowedHosts` (see [Remote access](#remote-access)); setting
  an API key also turns the check off.
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

Then delete the `HSA_OVERRIDE_GFX_VERSION` line from step 2: it makes the
runtime report gfx1030, so it only belongs with the gfx1030 build on a
gfx1031/gfx1032 card. `STRATA_HIP_PROMPT_F16` and
`STRATA_HIP_ADAPT_KERNEL_COPY` are gfx1030 workarounds too; drop them unless
you hit what they fix. The RAM and VRAM numbers in `args` are tuned to this
machine as well.

The Gyro trellis prompt kernels are off, since they hang an RX 6600 partway
through long prompts. Upstream validates them only on gfx1151; to turn them
back on for that GPU:

```nix
services.strata.package = pkgs.strata.override {
  gpuTargets = [ "gfx1151" ];
  gyroPromptKernels = true;
};
```

### RX 9000 series (gfx1201)

```nix
services.strata.package = pkgs.strata.override {
  gpuTargets = [ "gfx1201" ];
  gyroPromptKernels = true;
};
```

No `HSA_OVERRIDE_GFX_VERSION`: nixpkgs' ROCm supports gfx1201 natively. The
Gyro prompt kernels ran cleanly on an RX 9070 XT, and the server applies its
RDNA4 defaults by itself. Measurements are under "RX 9070 XT results".

### More than one AMD card

The ROCm runtime numbers every card it sees, and the engine runs on the first.
To give Strata one card, a desktop or game GPU beside it for instance, pin it
by the UUID `rocminfo` prints for it:

```nix
services.strata.environment.ROCR_VISIBLE_DEVICES = "GPU-71ced39f82cbac4d";
```

A UUID stays with the card when the slots change; an index (`"1"`) does not.
Drop `HSA_OVERRIDE_GFX_VERSION` when the pinned card doesn't need it: it
applies to every card in the process. The server's own GPU readings (`/metrics`,
the Monitor, the free-VRAM check) follow the same pin.

## Flake outputs

| Output | What |
| --- | --- |
| `packages.x86_64-linux.strata` (`default`) | `strata` (engine), `strata-server`, `strata-iq-pack` |
| `packages.x86_64-linux.strata-iq-pack` | `strata-iq-pack` alone, without ROCm; `.mkPack` builds a model's pack |
| `packages.x86_64-linux.strata-vision` | `strata-vision`, the CPU picture reader `services.strata.vision` runs |
| `packages.x86_64-linux.strata-dflash2` | the DFlash2 drafter packs for Qwen3.8-Flash-Next (a 1.2 GB download from Inco AI, Apache-2.0) |
| `nixosModules.default` | `services.strata` |
| `overlays.default` | adds `pkgs.strata`, `pkgs.strata-iq-pack`, `pkgs.strata-vision` and `pkgs.strata-dflash2` (the NixOS module applies it itself) |
| `apps.x86_64-linux.update` | bumps `versions.nix` to the newest release |

```bash
nix run github:kennethhoff/strata-nix -- --help   # strata-server
```

## Updating

For forks and maintainers: run this inside a clone of this repo.

```bash
nix run .#update
```

`versions.nix` also pins the llama.cpp commit Strata's CMake takes ggml from
(its `GIT_TAG`), which the sandboxed build can't fetch; the updater reads it from
the release, and the build fails if the two drift apart.

The flake stays on Strata 0.2.12: on this machine 0.2.13.1 added about 1.8 s to
every request (three runs each). 0.2.13.1 also ships ggml in its source and
drops that `GIT_TAG`, so the updater stops with an error there instead of
moving to it.

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
| `nativeGguf` | from `model` | The GGUF `--native` and the picture reader use; a split model's first shard by its own name. See below. |
| `pleGguf` | `null` | A standalone n-gram table for a `-noPLE` model. See below. |
| `modelName` | (required) | The model id the API reports. |
| `tokenizer` | from `model` | The pack's tokenizer directory; required when `model` is unset. |
| `maxContext` | `65536` | Longest context the engine accepts, in tokens. |
| `args` | `[ ]` | Engine arguments (`strata --help`). |
| `effortPosition` | `"start"` | Where a request's reasoning effort goes in the prompt: `"start"` (Strata's default) or `"end"`, which keeps the cached conversation when the effort changes. |
| `learnExpertProfile` | `false` | Saves the expert ranking learned from traffic to `/var/lib/strata`; the next start uses it instead of `--expert-profile`. |
| `drafting` | `null` | Which drafter guesses ahead: `"mtp"`, `"dflash2"`, `"auto"` or `"off"`; unset leaves it to the server. See below. |
| `dflash2` | `null` | A directory with the DFlash2 drafter packs, e.g. `pkgs.strata-dflash2`. See below. |
| `userArgs` | `[ ]` | Engine options the server keeps over the ones it generates, e.g. DFlash2's `--spec` and `--draft-conf`. |
| `vision.enable` | `false` | Accepts pictures (OpenAI `image_url`, Anthropic `image` blocks); see below. |
| `vision.mmproj` | ISTA's Flash-Next mmproj | The model's picture encoder; the default fits every Qwen3.8-Flash-Next quant, Gyro's included. |
| `vision.model` | from `model` | The text GGUF the reader takes the vocabulary from. |
| `vision.maxTokens` | `300` | Most image tokens one picture becomes (`0`: no limit). |
| `vision.threads` | `null` | CPU threads of the reader. |
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

### Split and `-noPLE` models

A split model (`…-00001-of-00002.gguf` and so on) must reach the engine under
its first shard's own name: Strata finds the other shards by rewriting that
part of the name, and refuses a shard opened as `model.gguf` ("is shard 1 of
N, but it was opened as a whole model"). Keep the shards beside each other and
point `nativeGguf` at the first:

```nix
services.strata = {
  model = "/srv/strata/iq2-xs";
  nativeGguf = "/srv/strata/iq2-xs/Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00001-of-00002.gguf";
};
```

A `-noPLE` file leaves out the n-gram (PLE) table, which is the base model's
and the same in every Flash-Next quant. Give the table as its own file, for
example one of
[Delgon/Qwen3.8-Flash-Next-PLE-GGUF](https://huggingface.co/Delgon/Qwen3.8-Flash-Next-PLE-GGUF):

```nix
services.strata = {
  model = "/srv/strata/gyro-m";
  pleGguf = "/srv/strata/Qwen3.8-Flash-Next-PLE-IQ4_NL.gguf";
};
```

This adds `--ple-gguf` and `--native-dense-gguf` with the native GGUF. The
second is not optional: without it the engine reads the table as a weight
shard and stops with "missing qwen4exp.block_count". The table can't come from
another quant's files either: a whole model GGUF fails on duplicate dense
tensors, and a split shard's metadata names a different first shard.

### `drafting` and `dflash2`

The engine decodes faster when a drafter guesses a few tokens ahead and one
pass checks them. The model's own MTP layer (`--mtp`, `--spec`) is the
default. DFlash2 is a separate draft model for Qwen3.8-Flash-Next:

```nix
services.strata = {
  drafting = "dflash2";
  dflash2 = pkgs.strata-dflash2;
  userArgs = [ "--spec" "8" "--draft-conf" "0.7" ];
};
```

- The server rewrites the drafter's engine options at every start from
  `drafting`, so `--draft dflash2` in `args` alone does nothing: it removes
  the option and starts the MTP, or no drafter if `--mtp` is gone too.
- It takes the drafter only from `dflash2/` two levels above `--pack`.
  `dflash2` therefore serves `model` through a folder that links both; with
  `model` unset, lay the directories out that way yourself.
- Keep `--mtp <dir>` in `args`: the server reads the draft vocabulary from it
  and falls back to the MTP when DFlash2 cannot start.
- With DFlash2 the server sets the verify window and confidence itself (a
  window of 6, a confidence from the card's expert slots). `userArgs` wins
  over those.

It is off unless set. Measurements on an RX 9070 XT are in the
[nixos-desktop notes](https://github.com/KennethHoff/nix/blob/master/pkgs/strata/README.md).

### `vision`

```nix
services.strata.vision.enable = true;
```

adds `--vision` to the engine and starts `strata-vision` beside it, which reads
each picture on the CPU with the model's mmproj (a 0.9 GB download, pinned to
the commit Strata's setup uses) and hands the engine its embeddings. It takes
no VRAM, which is what Strata does itself on cards under 24 GB. The mmproj is
not part of the pack, so turning this on does not rebuild it.

## What optimizations have we done

Everything below was measured with Strata 0.2.12 on the machine this flake
targets: RX 6600 (gfx1032, 8 GB, PCIe 4.0 x8), Ryzen 9 3900X, 32 GB RAM, an NVMe SSD, three
monitors, serving an abliterated variant of Gyro-S (not the standard one step 3a
installs, which wasn't benchmarked, so the figures may not carry over). Most figures are one run each, and two
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
below already in) against the settings in step 2, first with the RAM at
2666 MT/s (one run each), then at its rated 3200 MT/s (median of three runs,
range in brackets):

| | Before | After, 2666 MT/s | After, 3200 MT/s |
| --- | --- | --- | --- |
| 25K-token prompt | 164 s (163 tok/s) | 104 s (258 tok/s) | 98 s (274 tok/s; 241-278) |
| 9.2K / 9.4K-token prompt | 53 s / 53 s | 36 s / 37 s | 33 s / 34 s (33-39 / 33-40) |
| Decode (16 prompts) | 18.9 tok/s | 20.2 tok/s | 20.5 tok/s (20.4-20.8) |
| Experts cached in VRAM | 1,526 | 1,956 | 1,956 |
| Prompt chunk | 2,816 tokens | 3,328 tokens | 3,328 tokens |
| Context cap | 65,536 | 131,072 | 131,072 |
| RAM free with Strata loaded | 5.1-6.7 GiB | 4.2-4.7 GiB | 6.5 GiB (first run only) |

The slowest of the three 3200 MT/s runs was slow throughout (prompts 39-40 s),
which points at the machine rather than Strata; the other two read the 25K
prompt at 274-278 tok/s.

These are synthetic benchmarks: long, repetitive lists of numbered records
with one question at the end, which read faster than real conversations. Don't
expect 258-274 tok/s in practice. Over seven real agent requests, prompts read at
about 127 tok/s, half the benchmark rate. Use the table to compare settings,
not to predict real speed.

The prompt chunk is the number of prompt tokens read per batch (`--prefill`);
its buffers come out of the VRAM expert cache, and `--prefill auto` picks the
largest chunk the cache can lend.

Prompt reading is what matters most: in those real requests about 89% of the
engine's time went to reading prompts and 11% to writing answers.

### Kept

Each row below and in "Tried and dropped" compares against the state at the time
it was tried, not against the result table, so figures differ between rows.

| Setting | Why | Measured |
| --- | --- | --- |
| `gfx1030` build + `HSA_OVERRIDE_GFX_VERSION=10.3.0` | nixpkgs' rocBLAS has no gfx1032 kernels; a native build would mean rebuilding rocBLAS. | Builds and runs; Strata's ctest suite passed on the card (run by hand once), except the CPU-side bit-exactness checks against ggml on AVX2. |
| Gyro prompt kernels off (`gyroPromptKernels = false`) | With them the GPU hung partway through a 7.4K-token prompt, also with the workarounds below. | Without: 4 of 4 fresh 7.4K prompts read cleanly at 157-160 tok/s. |
| `STRATA_HIP_ADAPT_KERNEL_COPY=1` | Upstream's workaround for a GPU hang during decode's expert swaps on RDNA2. | Stopped a decode hang seen once without it; cost not measured. |
| `STRATA_HIP_PROMPT_F16=1` | rocBLAS on gfx1030 is tuned only for FP16-in, FP16-out products. | 9.2K prompt 68 s → 48 s, 9.4K 71 s → 36 s, same session, answers still correct. |
| `--resident-budget-gib 20` | Unbounded, the engine put 24 GiB of experts in RAM and a 25K prompt got OOM-killed. | No more OOM kills; speed not compared. |
| `STRATA_RESIDENT_HEADROOM_GIB=4` (was 6) | The RAM tier is cut to free RAM at start minus this; at 6 the 20 GiB budget came out at 17.7 GiB. | A bigger tier on a given day; how big depends on what the desktop holds at start. |
| `STRATA_RAM_ADAPT=1` + `learnExpertProfile` | Experts missing from RAM are read from disk on every use; hot ones now replace unused ones. | 2,883 experts swapped in during one session; decode gain not separable from other changes. |
| `--kv-resident 20480` with a 131K cap | The whole K/V was reserved in VRAM, taking room from the expert cache and the prompt chunk. | Raised the cap from 65K to 131K while prompts got faster (table above). A 107K-token conversation answered at 24 tok/s. |
| `effortPosition = "end"` | Changing the thinking level rewrote the first system message, so the whole conversation was read again. | Not measured here. |
| `--spec 2`, no draft head | Native packs require a verify window of 2+. | See the draft head below. |
| `MemorySwapMax = 0` on the unit (the module sets it) | A swapped-out expert turns a memory read into a disk read. | With swap allowed, a 25K prompt stalled for 2+ minutes with 15 GiB in swap. |

### Tried and dropped

| Tried | Result |
| --- | --- |
| MTP draft head (`--mtp`, `--spec 4`) | Decode 20.2 → 23.3 tok/s, but its 1 GiB of VRAM cut the prompt chunk from 3,328 to 1,280 tokens: a 25K prompt read at 184 instead of 258 tok/s, and every reply started 1.7 s later. Only replies over about 150 tokens come out ahead. |
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
- `STRATA_RESIDENT_PIN=0`: Strata's troubleshooting guide says a 32 GB PC
  can stall with `--resident-budget-gib` because the budget is locked in RAM,
  leaving the OS little room; this keeps it pageable. This machine is such a
  PC with a 20 GiB budget.
- More RAM: room for `--kv-grow`, the PLE table in RAM and a larger quant.
## RX 9070 XT results

A second card, not this flake's default target: the settings below live in
the host config, and the module's defaults stay as described above.

Measured on 2026-11-16 with Strata 0.2.12 on the same PC after an upgrade: an
RX 9070 XT (gfx1201, 16 GB, PCIe 4.0 x16) running Strata alone, the RX 6600
driving the desktop, and 96 GB of DDR4-3200. Strata is built with
`gpuTargets = [ "gfx1201" ]`, without `HSA_OVERRIDE_GFX_VERSION`, and pinned to
the card with `ROCR_VISIBLE_DEVICES`. Every figure comes from a trial instance
of the service with the same unit settings, one run unless a range is given.

### Configuration

Gyro-M (agentionai's abliterated TQ2_0, the `-noPLE` file) with Delgon's
standalone IQ4_NL n-gram table, `gyroPromptKernels = true`, the MTP draft head
(`--mtp`, `--spec 4`, `--spec-min-p 0.5`), `--resident-budget-gib 40` and
`--vram-reserve-mib 512`. The rest is as on the RX 6600: `--kv int8`,
`--kv-resident 20480`, a 131K cap.

A `-noPLE` file needs both `--ple-gguf <table>` and
`--native-dense-gguf <model.gguf>`. With only the first, the engine reads the
table as a weight shard and stops with `missing qwen4exp.block_count`. The
table can't come from another model's GGUF either: a whole file fails on
duplicate dense tensors, and a split shard's metadata names a different first
shard.

### Against the RX 6600

The same `pkgs/strata/bench/full.sh` prompts as the RX 6600 table, all on
Gyro-S:

| | RX 6600, tuned | 9070 XT, RX 6600 settings | 9070 XT, + draft head |
| --- | --- | --- | --- |
| 25K-token prompt | 98 s (274 tok/s) | 18 s (1,496-1,515 tok/s) | 12 s (2,242 tok/s) |
| 9.2K-token prompt | 33 s | 7 s (1,242 tok/s) | 4 s (2,053 tok/s) |
| Decode (16 prompts) | 20.5 tok/s | 58.2 tok/s | 82.0 tok/s |
| Experts cached in VRAM | 1,956 | 10,873 | not recorded |

### Model comparison

Strata's standard suite (`strata bench run`, standard-v1, against the trial
server with `--url`), medians of three requests per case in tok/s. "RX 6600
settings" is Gyro-S without the draft head; the other columns have the draft
head and the 40 GiB budget. Ranges are over two runs.

| | Gyro-S, RX 6600 settings | ISTA IQ2_XS + refusal projection | Gyro-S + kernels | Gyro-M + kernels |
| --- | --- | --- | --- | --- |
| prompt-4k read | 743 | 1,953-2,140 | 2,048-2,063 | 1,990-2,000 |
| prompt-16k read | 1,644 | 2,908-2,951 | 2,732-2,771 | 2,740-2,742 |
| Decode, short | 56.4 | 71.3-79.4 | 81.3-81.4 | 69.0-74.5 |
| Decode, 4k / 16k | 60.3 / 61.7 | 68.1-68.5 / 68.6-70.1 | 85.6-87.3 / 79.0-85.4 | 69.6-76.1 / 67.8-68.9 |
| Checks passed | 12/12 | 24/24 | 24/24 | 24/24 |

The suite's 12 checks (instructions, retrieval, tool calls) passed for every
model, so they don't separate quality. By Strata's own KL figures Gyro-M is the
closest of the three to the full model: about 0.157, level with IQ3_XXS,
against 0.236 for IQ2_XS and 0.268 for Gyro-S.

A replay of the 23 coding-agent turns in Strata's
`tools/agent_turns_bench.py` (4K to about 100K tokens, each turn extending the
last, 256 new tokens a turn), sent to the running server:

| | Wall time | Median decode | Median prompt read | Tool calls |
| --- | --- | --- | --- | --- |
| IQ2_XS + refusal projection | 198 s | 83.5 tok/s | 2,204 tok/s | 20 of 23 |
| Gyro-S + kernels | 200 s | 87.1 tok/s | 2,064 tok/s | 20 of 23 |
| Gyro-M + kernels | 204 s | 74.2 tok/s | 2,029 tok/s | 18 of 23 |
| Gyro-M, no kernels | 249 s | 73.2 tok/s | 1,622 tok/s | 19 of 23 |

Turns without a tool call ended mid-thought at the 256-token cap. None
produced a malformed call.

### Kept

| Setting | Measured |
| --- | --- |
| Strata on the 9070 XT, the desktop on the RX 6600 | The RX 6600 drives every monitor, so long prompts don't stall the desktop and Strata gets all 16 GB. |
| `--vram-reserve-mib 512` | Strata's own reserve for a card that drives no display. |
| MTP draft head, `--spec 4` | Gyro-S decode 58 → 82 tok/s, 9K-token prompts 1,240 → 2,050 tok/s. Ten record lookups over 9K-68K-token prompts scored 9 of 10 with and without it (`pkgs/strata/bench/accuracy.sh`). |
| `--resident-budget-gib 40` | With the draft head, a 96K-token prompt read at 2,614 tok/s instead of 1,867. |
| `gyroPromptKernels = true` | No hang on this card. Gyro-M 4K prompts 1,420 → 1,995 tok/s, 16K 2,415 → 2,740; the agent replay 249 → 204 s. |
| Gyro-M | Strata's KL figures above; within 3% of the others in the agent replay. |

The draft head does change some answers. The 25K-token question in `full.sh`
(record 537) came back as record 767's value in 8 of 9 runs with the draft head
at `--spec 4` and 1 of 4 at `--spec 2`, against 0 of 7 without it. The
ten-question set above shows no difference, so this looks like one borderline
question rather than a general loss.

### Tried and dropped

| Tried | Result |
| --- | --- |
| `--kv-resident 131072` | No faster, a 96K-token prompt included. |
| `--batch 2` | Two requests at once gave 72.4 tok/s combined, against 82 for one alone; VRAM expert hits fell from 96% to 84%. |
| `STRATA_HIP_PROMPT_F16=1` | 9K-token prompts read at 939-1,054 tok/s instead of about 2,000. It only helps gfx103x. |
| The RX 6600 as a helper expert cache (`--expert-cache-device1`) | Hyprland crashed while the first prompt was read: the card that draws the desktop can't also run Strata. |
| ISTA IQ2_XS with Strata's refusal projection | As fast as Gyro-M and 24/24 in the suite, but further from the full model and not abliterated in its weights. |
| Qwen3.6-35B-A3B UD-Q4_K_XL | Decode 31-36 tok/s, and a wrong answer on a 96K-token prompt. |

### Not tried yet

- A 262K context cap: VRAM no longer limits it, but the model was trained to
  262,144 tokens and nothing past 131K was measured.
- Gyro-L: its pair-trellis expert types (TQP5-TQP7) have no kernels in the
  source tree Strata's HIP build compiles, so its experts would likely run on
  the CPU.
- Power limits or undervolting.

