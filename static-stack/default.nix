{
  release ? false,
}:
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
  pyopenssl-fix-test-buffer-size-overlay = final: previous: {
    python36 = previous.python36.override {
      packageOverrides = self: super: {
        cython = super.cython.overridePythonAttrs (old: rec {
          # TODO Cython tests for unknown reason hang with musl. Remove when that's fixed.
          # See https://github.com/nh2/static-haskell-nix/issues/6#issuecomment-421852854
          doCheck = false;
        });
        pyopenssl = super.pyopenssl.overridePythonAttrs (old: rec {
          patches = [
            # TODO Remove when https://github.com/pyca/pyopenssl/commit/b2777a465b669fb647dbac0a92919cb05458707b is available in nixpkgs
            (final.fetchpatch {
              name = "wantWriteError-test-buffer-size.patch";
              url = "https://github.com/pyca/pyopenssl/commit/b2777a465b669fb647dbac0a92919cb05458707b.patch";
              sha256 = "0igksnl0cd5cx8f38bfjdriwdrzbw6ciy0hs805s84mprfwhck8d";
            })
          ];
        });
      };
    };
  };

  normalPkgs = import (fetchTarball https://github.com/nh2/nixpkgs/archive/442912b4f19644311700b43b3b5247c6291d785a.tar.gz) {};

  # In `survey` we provide a nixpkgs set with some fixes; import it here.
  pkgs = (import ../survey/default.nix {
    inherit normalPkgs;
    overlays = [ pyopenssl-fix-test-buffer-size-overlay ];
  }).pkgs;

  # TODO Use `pkgs.stack2nix` instead of this once `stack2nix` 0.2 is in `pkgs`
  stack2nix_src = pkgs.fetchFromGitHub {
    owner = "input-output-hk";
    repo = "stack2nix";
    rev = "v0.2.1";
    sha256 = "1ihcp3mr0s89xmc81f9hxq07jw6pm3lixr5bdamqiin1skpk8q3b";
  };
  stack2nix = import (stack2nix_src + "/default.nix") {};

  # Script that runs `stack2nix` on a given stack source dir.
  # Arguments given to the script are given to `stack2nix`.
  # Running the script creates file `stack.nix`.
  stack2nix-script =
    # `stack2nix` requires `cabal` on $PATH.
    # We put our nixpkgs's version of `nix` on $PATH for reproducibility.
    pkgs.writeScript "stack2nix-build-script.sh" ''
      #!/usr/bin/env bash
      set -eu -o pipefail
      PATH=${pkgs.cabal-install}/bin:${normalPkgs.nix}/bin:$PATH ${stack2nix}/bin/stack2nix -o stack.nix $@
    '';

  # Apply patch to generated stack2nix output to work around
  # 'libyaml' dependency to be named 'yaml'; see
  #     https://github.com/NixOS/cabal2nix/issues/378
  # Note this patch depends on
  #     https://github.com/commercialhaskell/stack/blob/a2489de02/stack.yaml#L27
  # which includes
  #     https://github.com/snoyberg/yaml/pull/151/commits/ba216731cd5bf4264e9ad95d55616ff1a9edfac5
  # This patch doesn't apply and can be removed if either
  #   * the `stack` version to be compiled has `yaml` older than in the line mentioned above, or
  #   * the `cabal2nix` version in use has https://github.com/NixOS/cabal2nix/commit/67e3189f fixed
  stack2nix-output = pkgs.runCommand "stack.nix-patched" {} ''
    cp ${./stack.nix} $out
    patch -p1 $out ${./stack-libyaml-dependency-name-cabal2nix-issue-378.patch}
  '';

  enableCabalFlags = flags: drv: builtins.foldl' (d: flag: pkgs.haskell.lib.enableCabalFlag d flag) drv flags;
  setStackFlags = drv:
    if release
      then enableCabalFlags [ "hide-dependency-versions" "supported-build" ] drv
      else drv;
  # Builds a static stack executable from a `stack.nix` file generated
  # with `stack2nix`.
  static_stack = setStackFlags (import ../survey/default.nix {
    normalPkgs = pkgs;
    normalHaskellPackages = import stack2nix-output {
      inherit pkgs;
    };
  }).haskellPackages.stack;
  # TODO check if `overrideCabal super.stack (old: { executableToolDepends = [ pkgs.git ]; })`
  # is necessary here now that it's removed from `survey`

  # Script that runs `nix-build` to build the final executable.
  # We do this to fix the version of `nix` to the one in our nixpkgs
  # for reproducibility, as changing nix versions can change the build env.
  # Arguments given to the script are given to `nix-build`.
  build-script =
    pkgs.writeScript "stack-build-script.sh" ''
      #!/usr/bin/env bash
      set -eu -o pipefail
      set -x
      ${normalPkgs.nix}/bin/nix-build --no-out-link -A static_stack $@
    '';

in {
  inherit pkgs;
  inherit stack2nix-script;
  inherit static_stack;
  inherit build-script;
}
