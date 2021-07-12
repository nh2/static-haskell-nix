# Builds a static `stack` executable from a stack source dir.
#
# Usage:
#
#     $(nix-build --no-link -A fullBuildScript --argstr stackDir /absolute/path/to/stack/source)
{
  stackDir ? "/absolute/path/to/stack/source",
  stack2nix-output-path ? "custom-stack2nix-output.nix",
}:
let
  cabalPackageName = "stack";
  compiler = "ghc8104"; # matching stack-lts-12.yaml

  pkgs = import ../nixpkgs {};

  stack2nix-script = import ../static-stack2nix-builder/stack2nix-script.nix {
    inherit pkgs;
    inherit compiler;
    stack-project-dir = stackDir; # where stack.yaml is
    hackageSnapshot = "2021-07-12T00:00:00Z"; # pins e.g. extra-deps without hashes or revisions
  };

  static-stack2nix-builder = import ../static-stack2nix-builder/default.nix {
    normalPkgs = pkgs;
    inherit cabalPackageName compiler stack2nix-output-path;
    # disableOptimization = true; # for compile speed
  };

  static_package = with pkgs.haskell.lib;
    overrideCabal
      (appendConfigureFlags
        static-stack2nix-builder.static_package
        [
          # Official release flags:
          "-fsupported-build"
          "-fhide-dependency-versions"
          "-f-disable-git-info" # stack2nix turns that on, we turn it off again
        ]
      )
      (old: {
        # Enabling git info needs these extra deps.
        # TODO Make `stack2nix` accept per-package Cabal flags,
        #      so that `cabal2nix` would automatically add
        #      the right dependencies for us.
        executableHaskellDepends = (old.executableHaskellDepends or []) ++
          (with static-stack2nix-builder.haskell-static-nix_output.haskellPackages; [
            githash
            optparse-simple
          ]);
        # Put `git` on PATH, because `githash` calls it.
        preConfigure = ''
          export PATH=${pkgs.git}/bin:$PATH
          git --version
        '';
      });

  # Full invocation, including pinning `nix` version itself.
  fullBuildScript = pkgs.writeShellScript "stack2nix-and-build-script.sh" ''
    set -eu -o pipefail
    STACK2NIX_OUTPUT_PATH=$(${stack2nix-script})
    ${pkgs.nix}/bin/nix-build --no-link -A static_package --argstr stack2nix-output-path "$STACK2NIX_OUTPUT_PATH" "$@"
  '';

in
  {
    inherit static_package;
    inherit fullBuildScript;
    # For debugging:
    inherit stack2nix-script;
    inherit static-stack2nix-builder;
  }
