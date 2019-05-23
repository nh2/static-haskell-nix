# Builds a static `stack` executable from a stack source dir.
#
# Usage:
#
#     $(nix-build --no-link -A run-stack2nix-and-static-build-script --argstr stackDir /absolute/path/to/stack/source)
{
  stackDir ? "/absolute/path/to/stack/source",
}:
let

  upstreamNixpkgs = import ../nixpkgs {};

  static-stack2nix-builder = import ../static-stack2nix-builder/default.nix {
    cabalPackageName = "stack";
    normalPkgs = upstreamNixpkgs;
    compiler = "ghc822"; # matching stack.yaml
    hackageSnapshot = "2019-05-08T00:00:00Z"; # pins e.g. extra-deps without hashes or revisions
    stack2nix-stack-project-dir = stackDir; # where stack.yaml is
    # disableOptimization = true; # for compile speed
  };

in
  static-stack2nix-builder // {
    static_package =
      with upstreamNixpkgs.haskell.lib;
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
            export PATH=${upstreamNixpkgs.git}/bin:$PATH
            git --version
          '';
        });
  }
