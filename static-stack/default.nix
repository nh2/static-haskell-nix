# Builds a static `stack` executable from a stack source dir.
#
# Usage:
#
#   $(nix-build --no-out-link -A stack2nix-script) /path/to/stack/source --stack-yaml stack-nightly.yaml && nix-build --no-out-link -A static_stack
#
# We do it this way instead of writing a derivation that
# does that for you because as of writing, `stack2nix` doesn't support
# being run from within a nix build, because it calls `cabal update`.
let
  # In `survey` we provide a nixpkgs set with some fixes; import it here.
  pkgs = (import ../survey/default.nix {
    normalPkgs = import (fetchTarball https://github.com/nh2/nixpkgs/archive/50677e464359947f2a71cfd497c4022e3cdf8c7d.tar.gz) {};
  }).pkgs;

  # TODO Use `pkgs.stack2nix` instead of this once `stack2nix` 0.2 is in `pkgs`
  stack2nix_src = pkgs.fetchFromGitHub {
    owner = "input-output-hk";
    repo = "stack2nix";
    rev = "88fd8be0cad55e4f29575c5d55645f6321201c17";
    sha256 = "13j7zl6hxs8bqblx4b38lr9nhda95rcnj44d0k2x1mq2xgsnkg92";
  };
  stack2nix = import (stack2nix_src + "/default.nix") {};

  # Script that runs `stack2nix` on a given stack source dir.
  # Arguments given to the script are given to `stack2nix`.
  # Running the script creates file `stack.nix`.
  stack2nix-script =
    # `stack2nix` requires `cabal` on $PATH.
    pkgs.writeScript "stack-build-script.sh" ''
      #!/usr/bin/env bash
      set -eu -o pipefail
      PATH=${pkgs.cabal-install}/bin:$PATH ${stack2nix}/bin/stack2nix -o stack.nix $@
    '';

  # Builds a static stack executable from a `stack.nix` file generated
  # with `stack2nix`.
  static_stack = (import ../survey/default.nix {
    normalPkgs = pkgs;
    normalHaskellPackages = import ./stack.nix {
      inherit pkgs;
    };
  }).haskellPackages.stack;

in {
  inherit stack2nix-script;
  inherit static_stack;
}
