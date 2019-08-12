# Creates a script that runs `stack2nix` on a given stack project's source dir.
# Arguments given to the script are given to `stack2nix`.
# Running the script adds the generated output file to the nix store
# and prints the store store path to stdout.
#
{
  # nixpkgs to use.
  pkgs,

  # Path to directory containing `stack.yaml`.
  stack-project-dir,

  # Hackage snapshot time to pass to `stack2nix`.
  # This determines the versions of package revisions in stack `extra-deps`
  # that are not pinned to a revision.
  # Example: "2019-05-08T00:00:00Z"
  hackageSnapshot,

  # stack.yaml file to use.
  # Must be in the `stack-project-dir` (usually next to wherever the normal
  # stack.yaml is) because Stack will search for its `packages` relative
  # to this file.
  # Useful when you want to give a customised stack.yaml,
  # e.g. when adding extra cabal flags to packages for static builds,
  # such as the `integer-simple` flag to the `text` library.
  stack-yaml ? "stack.yaml",
}:
  # `stack2nix` requires `cabal` on $PATH.
  # We put our nixpkgs's version of `nix` on $PATH for reproducibility.
  # Everything but `nix-store --add` must print to stderr so that the
  # script prints only the final store path to stdout.
  # The output is generated to a `mktemp --directory` so that parallel
  # invocations don't influence each other.
  # Note in this script we should qualify all executables from nix packages
  # (or put them on PATH accordingly)
  # as it's run in the user's shell (not in a normal nix build environment,
  # since `stack2nix` needs internet access), so we can't make any assumptions
  # about shell builtins or what's on PATH. For example, if `mktemp` is from
  # `busybox` instead of `coreutils`, it may not support the `--directory`
  # option.
  # And for example the `nixos/nix` Docker container is minimal and supplies
  # many executables from `busybox`, such as `mktemp` and `wget`.
  let
    # Shell utils called by stack2nix or the script itself:
    add_to_PATH = [
      "${pkgs.coreutils}/bin" # `mktemp` et al
      "${pkgs.cabal-install}/bin" # `cabal`
      "${pkgs.nix}/bin" # various `nix-*` commands
      "${pkgs.wget}/bin" # `wget`
    ];

    fixed_stack2nix =
      let
        # stack2nix isn't compatible with Stack >= 2.0, see
        # https://github.com/input-output-hk/stack2nix/issues/168.
        # Current versions of nixpkgs master have Stack >= 2.0, see
        # https://github.com/NixOS/nixpkgs/issues/63691.
        # We thus fetch the `stack2nix` binary from an older nixpkgs version
        # that doesn't have Stack >= 2.0.
        # This means that `static-stack2nix-builder` may not work on `stack.yaml`
        # files that aren't compatible with Stack < 2.0.
        stack2nix_pkgs = import (fetchTarball https://github.com/NixOS/nixpkgs/archive/e36f91fa86109fa93cac2516a9365af57233a3a6.tar.gz) {};
      in
        # Some older stack2nix versions have fundamental problems that prevent
        # stack2nix from running correctly. Fix them here, until these old versions
        # are faded out of current nixpkgs. Especially:
        #   * "Make sure output is written in UTF-8."
        #     https://github.com/input-output-hk/stack2nix/commit/cb05818ef8b58899f15641f50cb04e5473b4f9b0
        #
        # Versions < 0.2.3 aren't supported, force-upgrade them to 0.2.3.
        if stack2nix_pkgs.lib.versionOlder stack2nix_pkgs.stack2nix.version "0.2.3"
          then stack2nix_pkgs.haskellPackages.callCabal2nix "stack2nix" (stack2nix_pkgs.fetchFromGitHub {
            owner = "input-output-hk";
            repo = "stack2nix";
            rev = "v0.2.3";
            sha256 = "1b4g7800hvhr97cjssy5ffd097n2z0fvk9cm31a5jh66pkxys0mq";
          }) {}
          else stack2nix_pkgs.stack2nix;
  in
  pkgs.writeScript "stack2nix-build-script.sh" ''
    #!/usr/bin/env bash
    set -eu -o pipefail
    export NIX_PATH=nixpkgs=${pkgs.path}
    export PATH=${pkgs.lib.concatStringsSep ":" add_to_PATH}:$PATH
    OUT_DIR=$(mktemp --directory -t stack2nix-output-dir.XXXXXXXXXX)
    set -x
    ${fixed_stack2nix}/bin/stack2nix "${stack-project-dir}" --stack-yaml "${stack-yaml}" --hackage-snapshot "${hackageSnapshot}" -o "$OUT_DIR/stack2nix-output.nix" "$@" 1>&2
    nix-store --add "$OUT_DIR/stack2nix-output.nix"
  ''
