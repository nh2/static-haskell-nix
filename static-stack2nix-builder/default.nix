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
  # The name of the cabal package to build.
  cabalPackageName ? "myproject",

  # Hackage snapshot time to pass to `stack2nix`.
  # This determines the versions of package revisions in stack `extra-deps`
  # that are not pinned to a revision.
  hackageSnapshot ? "2019-05-08T00:00:00Z",

  # Path to directory in which `stack2nix` is run and into which it drops
  # its output file.
  # Made customisable so that other projects can import this script we're
  # in here via URL.
  runDir ? ./.,

  # Pin nixpkgs version.
  normalPkgs ? import (fetchTarball https://github.com/NixOS/nixpkgs/archive/88ae8f7d55efa457c95187011eb410d097108445.tar.gz) {},
}:
let
  # In `survey` we provide a nixpkgs set with some fixes; import it here.
  pkgs = (import ../survey/default.nix {
    inherit normalPkgs;
  }).pkgs;

  # Pin `stack2nix` version.
  # TODO Use `pkgs.stack2nix` instead of this once `stack2nix` 0.2 is in `pkgs`
  stack2nix_src = pkgs.fetchFromGitHub {
    owner = "input-output-hk";
    repo = "stack2nix";
    rev = "v0.2.1";
    sha256 = "1ihcp3mr0s89xmc81f9hxq07jw6pm3lixr5bdamqiin1skpk8q3b";
  };
  stack2nix = import (stack2nix_src + "/default.nix") {};

  # Script that runs `stack2nix` on a given stack project's source dir.
  # Arguments given to the script are given to `stack2nix`.
  # Running the script creates file `stack2nix-output.nix`.
  stack2nix-script =
    # `stack2nix` requires `cabal` on $PATH.
    # We put our nixpkgs's version of `nix` on $PATH for reproducibility.
    pkgs.writeScript "stack2nix-build-script.sh" ''
      #!/usr/bin/env bash
      set -eu -o pipefail
      export NIX_PATH=nixpkgs=${normalPkgs.path}
      PATH=${pkgs.cabal-install}/bin:${normalPkgs.nix}/bin:$PATH ${stack2nix}/bin/stack2nix --hackage-snapshot "${hackageSnapshot}" -o stack2nix-output.nix $@
    '';

  # Builds static executables from a `stack2nix-output.nix` file generated
  # with `stack2nix`.
  static_package = (import ../survey/default.nix {
    normalPkgs = pkgs;
    normalHaskellPackages = import (runDir + "/stack2nix-output.nix") {
      inherit pkgs;
    };
  }).haskellPackages."${cabalPackageName}";

  # Script that runs `nix-build` to build the final executable.
  # We do this to fix the version of `nix` to the one in our nixpkgs
  # for reproducibility, as changing nix versions can change the build env.
  # Arguments given to the script are given to `nix-build`.
  static-build-script =
    pkgs.writeScript "static-build-script.sh" ''
      #!/usr/bin/env bash
      set -eu -o pipefail
      set -x
      ${normalPkgs.nix}/bin/nix-build --no-out-link -A static_package $@
    '';

in {
  inherit pkgs;
  inherit stack2nix-script;
  inherit static_package;
  inherit static-build-script;
}
