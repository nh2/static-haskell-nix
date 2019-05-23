# Helper to build static executables from a Haskell stack project's source dir.
# Use this after having generated a stack2nix output, e.g. with
# `stack2nix-script.nix`.
{
  # The name of the cabal package to build, e.g. "pandoc".
  cabalPackageName ? "myproject",

  # Compiler name in nixpkgs, e.g. "ghc864".
  # Must match the one in the `resolver` in `stack.yaml`.
  # If you get this wrong, you'll likely get an error like
  #     <command line>: cannot satisfy -package-id Cabal-2.4.1.0-ALhzvdqe44A7vLWPOxSupv
  # TODO: Make `stack2nix` tell us that.
  compiler ? "ghc864",

  # Path to `stack2nix` output that shall be used as Haskell packages.
  # You should usually give this the store path that `stack2nix-script` outputs.
  stack2nix-output-path,

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

  # Provide this to make builds extra reproducible by also pinning the version
  # of `nix` itself, as changing nix versions can change the build env.
  pinnedNix = normalPkgs.nix;

in {
  inherit static-haskell-nix_pkgsMusl;
  inherit stack2nix_output;
  inherit pkgs_with_stack2nix_packages_inside;
  inherit haskell-static-nix_output;
  inherit static_package;
  inherit pinnedNix;
}
