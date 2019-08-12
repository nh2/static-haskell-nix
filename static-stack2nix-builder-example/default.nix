# Run using:
#
#     $(nix-build --no-link -A fullBuildScript)
{
  stack2nix-output-path ? "custom-stack2nix-output.nix",
}:
let
  cabalPackageName = "example-project";
  compiler = "ghc864"; # matching stack.yaml

  # Pin nixpkgs version.
  pkgs = import (fetchTarball https://github.com/nh2/nixpkgs/archive/a2d7e9b875e8ba7fd15b989cf2d80be4e183dc72.tar.gz) {};

  # Pin static-haskell-nix version.
  static-haskell-nix = toString ../.;

  stack2nix-script = import "${static-haskell-nix}/static-stack2nix-builder/stack2nix-script.nix" {
    inherit pkgs;
    stack-project-dir = toString ./.; # where stack.yaml is
    hackageSnapshot = "2019-05-08T00:00:00Z"; # pins e.g. extra-deps without hashes or revisions
  };

  static-stack2nix-builder = import "${static-haskell-nix}/static-stack2nix-builder/default.nix" {
    normalPkgs = pkgs;
    inherit cabalPackageName compiler stack2nix-output-path;
    # disableOptimization = true; # for compile speed
  };

  # Full invocation, including pinning `nix` version itself.
  fullBuildScript = pkgs.writeScript "stack2nix-and-build-script.sh" ''
    #!/usr/bin/env bash
    set -eu -o pipefail
    STACK2NIX_OUTPUT_PATH=$(${stack2nix-script})
    ${pkgs.nix}/bin/nix-build --no-link -A static_package --argstr stack2nix-output-path "$STACK2NIX_OUTPUT_PATH" "$@"
  '';

in
  {
    static_package = static-stack2nix-builder.static_package;
    inherit fullBuildScript;
    # For debugging:
    inherit stack2nix-script;
    inherit static-stack2nix-builder;
  }
