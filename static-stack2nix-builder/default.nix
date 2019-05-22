# Builds static executables from a Haskell stack project's source dir.
# The source dir must contain a `stack.yaml` file.
#
# Usage:
#
#   $(nix-build --no-out-link -A stack2nix-script) /path/to/project/source && $(nix-build --no-out-link -A static-build-script)
#
# We do it this way instead of writing a derivation that
# does that for you because as of writing, `stack2nix` doesn't support
# being run from within a nix build, because it calls `cabal update`.
#
# If your project uses `package.yaml` files, you must `rm` them before
# the second `nix-build` invocation, because as of writing, `stack2nix`
# clutters the projects source directory with generated `.cabal` files.
{
  # The name of the cabal package to build, e.g. "pandoc".
  cabalPackageName ? "myproject",

  # Compiler name in nixpkgs, e.g. "ghc86".
  # Must match the one in the `resolver` in `stack.yaml`.
  # TODO: Make `stack2nix` tell us that.
  compiler ? "ghc864",

  # Hackage snapshot time to pass to `stack2nix`.
  # This determines the versions of package revisions in stack `extra-deps`
  # that are not pinned to a revision.
  hackageSnapshot ? "2019-05-08T00:00:00Z",

  # Path to directory containing `stack.yaml`.
  stack2nix-stack-project-dir,

  # String path to stack2nix shall drop its output.
  stack2nix-output-path ? "/tmp/stack2nix-output.nix",

  # Pin nixpkgs version.
  normalPkgs ? import (fetchTarball https://github.com/NixOS/nixpkgs/archive/88ae8f7d55efa457c95187011eb410d097108445.tar.gz) {},

  # Enable for faster building, but not proper releases.
  disableOptimization ? false,
}:
let

  static-haskell-nix_pkgsMusl = (import ../survey/default.nix {
    inherit normalPkgs;
    inherit compiler;
    inherit disableOptimization;
  }).pkgs;

  # Script that runs `stack2nix` on a given stack project's source dir.
  # Arguments given to the script are given to `stack2nix`.
  # Running the script creates the output file at `stack2nix-output-path`.
  stack2nix-script =
    # `stack2nix` requires `cabal` on $PATH.
    # We put our nixpkgs's version of `nix` on $PATH for reproducibility.
    normalPkgs.writeScript "stack2nix-build-script.sh" ''
      #!/usr/bin/env bash
      set -eu -o pipefail
      export NIX_PATH=nixpkgs=${normalPkgs.path}
      export PATH=${normalPkgs.cabal-install}/bin:${normalPkgs.nix}/bin:$PATH
      set -x
      ${normalPkgs.stack2nix}/bin/stack2nix "${stack2nix-stack-project-dir}" --hackage-snapshot "${hackageSnapshot}" -o "${stack2nix-output-path}" $@
    '';

  stack2nix_output = import stack2nix-output-path { pkgs = static-haskell-nix_pkgsMusl; };

  pkgs_with_stack2nix_packages_inside = static-haskell-nix_pkgsMusl.extend (final: previous: {
    haskell = final.lib.recursiveUpdate previous.haskell {
      packages."${compiler}" = stack2nix_output;
    };
  });

  haskell-static-nix_output = (import ../survey/default.nix {
    normalPkgs = pkgs_with_stack2nix_packages_inside;
    inherit compiler;
    inherit disableOptimization;
  });

  static_package = haskell-static-nix_output.haskellPackages."${cabalPackageName}";

  # Script that runs `nix-build` to build the final executable.
  # We do this to fix the version of `nix` to the one in our nixpkgs
  # for reproducibility, as changing nix versions can change the build env.
  # Arguments given to the script are given to `nix-build`.
  static-build-script =
    normalPkgs.writeScript "static-build-script.sh" ''
      #!/usr/bin/env bash
      set -eu -o pipefail
      set -x
      ${normalPkgs.nix}/bin/nix-build --no-link -A static_package $@
    '';

  # Runs both `stack2nix` and does the static nix-build in one go.
  # Arguments given to the script are given to `nix-build`.
  run-stack2nix-and-static-build-script =
    normalPkgs.writeScript "stack2nix-and-build-script.sh" ''
      #!/usr/bin/env bash
      set -eu -o pipefail
      ${stack2nix-script}
      ${static-build-script} $@
    '';

in {
  inherit static-haskell-nix_pkgsMusl;
  inherit stack2nix-script;
  inherit stack2nix_output;
  inherit pkgs_with_stack2nix_packages_inside;
  inherit haskell-static-nix_output;
  inherit static_package;
  inherit static-build-script;
  inherit run-stack2nix-and-static-build-script;
}
