# If this env var is set, use latest nixpkgs unstable.
# We use that for scheduled builds tracking nixpkgs unstable on CI.
# Of course that is NOT reproducible.
if builtins.getEnv "STATIC_HASKELL_NIX_CI_NIXPKGS_UNSTABLE_BUILD" == "1"
  then
    let
      # You can set e.g. to build with `master`:
      #     STATIC_HASKELL_NIX_CI_NIXPKGS_UNSTABLE_BUILD=1
      #     NIXPKGS_URL=https://github.com/NixOS/nixpkgs/archive/master.tar.gz
      NIXPKGS_URL_var = builtins.getEnv "NIXPKGS_URL";
      nixpkgsUrl =
        if NIXPKGS_URL_var != null && NIXPKGS_URL_var != ""
          then NIXPKGS_URL_var
          else "https://nixos.org/channels/nixpkgs-unstable/nixexprs.tar.xz";
      nixpkgs = import (fetchTarball nixpkgsUrl) {};
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
      # This is nixos-21.11 as of 2021-12-15.
      else import (fetchTarball https://github.com/NixOS/nixpkgs/archive/573095944e7c1d58d30fc679c81af63668b54056.tar.gz) {}
