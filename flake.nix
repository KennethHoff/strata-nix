{
  description = "Nix flake for Strata, the MoE inference engine with a VRAM/RAM/SSD expert cache (HIP build)";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # ROCm, and so the HIP build, exists in nixpkgs for x86_64-linux only.
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        strata = pkgs.callPackage ./package.nix { };
        strata-iq-pack = pkgs.callPackage ./iq-pack.nix { };
        default = strata;
      });

      overlays.default = import ./overlay.nix;

      nixosModules = rec {
        strata = ./module.nix;
        default = strata;
      };

      apps = forAllSystems (pkgs: {
        update = {
          type = "app";
          program = nixpkgs.lib.getExe (
            pkgs.writeShellApplication {
              name = "strata-update";
              runtimeInputs = with pkgs; [
                cacert
                coreutils
                curl
                git
                gnugrep
                gnused
                jq
                nix
              ];
              text = ''
                cd "$(git rev-parse --show-toplevel)"
              ''
              + builtins.readFile ./update.sh;
            }
          );
        };
      });

      checks = forAllSystems (pkgs: import ./tests { inherit pkgs self nixpkgs; });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
