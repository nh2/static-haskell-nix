# If a `./nixpkgs` submodule exists, use that.
# Note that this will take precedence over setting NIX_PATH!
# We prefer this such that `static-stack2nix-builder` and specifically
# `static-stack2nix-builder-example` can just import `nixpkgs.nix`
# in CI and when called during development to get the right version of
# nixpkgs.
if builtins.pathExists ./nixpkgs/pkgs
  then import ./nixpkgs {}
  # Pinned nixpkgs version; should be kept up-to-date with our submodule.
  else import (fetchTarball https://github.com/nh2/nixpkgs/archive/a2d7e9b875e8ba7fd15b989cf2d80be4e183dc72.tar.gz) {}
