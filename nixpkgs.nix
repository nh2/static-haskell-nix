# If this env var is set, use latest nixpkgs unstable.
# We use that for scheduled builds tracking nixpkgs unstable on CI.
# Of course that is NOT reproducible.
if builtins.getEnv "STATIC_HASKELL_NIX_CI_NIXPKGS_UNSTABLE_BUILD" == "1"
  then
     let
       nixpkgs = import (fetchTarball https://nixos.org/channels/nixpkgs-unstable/nixexprs.tar.xz) {};
       msg = "Using version ${nixpkgs.lib.version} of nixpkgs-unstable channel.";
     in builtins.trace msg nixpkgs
  else
    # If a `./nixpkgs` submodule exists, use that.
    # Note that this will take precedence over setting NIX_PATH!
    # We prefer this such that `static-stack2nix-builder` and specifically
    # `static-stack2nix-builder-example` can just import `nixpkgs.nix`
    # in CI and when called during development to get the right version of
    # nixpkgs.
    if builtins.pathExists ./nixpkgs/pkgs
      then import ./nixpkgs {}
      # Pinned nixpkgs version; should be kept up-to-date with our submodule.
      else import (fetchTarball https://github.com/nh2/nixpkgs/archive/aaa60de8d7a40712790e2a22b1d8941eda9dbf4b.tar.gz) {}
