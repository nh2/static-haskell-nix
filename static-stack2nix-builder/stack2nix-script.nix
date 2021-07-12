# Creates a script that runs `stack2nix` on a given stack project's source dir.
# Arguments given to the script are given to `stack2nix`.
# Running the script adds the generated output file to the nix store
# and prints the store store path to stdout.
#
{
  # nixpkgs to use.
  pkgs,

  # ghc to use; only because without a GHC on path, stack complains:
  #     stack2nix: No compiler found, expected minor version match with ghc-8.10.4 (x86_64) (based on resolver setting ...
  # This happens even when using the Stack API (as stack2nix does),
  # and stack2nix doen't currently accept or set the `--system-ghc`
  # flag to skip the check (maybe it should to eschew this option;
  # I suspect our operation here never uses GHC).
  # TODO: This shouldn't be necessary since `stack2nix` commit
  #           Set `--system-ghc` via stack API.
  #       But somehow stack2nix still complains about it;
  #       perhaps we didn't use the Stack API correctly.
  compiler,

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
      "${pkgs.haskell.compiler.${compiler}}/bin" # `ghc` version matching target stack.yaml
    ];

    fixed_stack2nix =
      pkgs.haskellPackages.callCabal2nix "stack2nix" (pkgs.fetchFromGitHub {
        owner = "nh2";
        repo = "stack2nix";
        rev = "c20097d4edf82256484a733544579d4b5e0f2808";
        sha256 = "1lpwc20q62z9a9fpksd9q10x1jz8l29psx4dqsff759srj4chy9p";
      }) {};
  in
  pkgs.writeShellScript "stack2nix-build-script.sh" ''
    set -eu -o pipefail
    export NIX_PATH=nixpkgs=${pkgs.path}
    export PATH=${pkgs.lib.concatStringsSep ":" add_to_PATH}:$PATH
    OUT_DIR=$(mktemp --directory -t stack2nix-output-dir.XXXXXXXXXX)
    set -x
    ${fixed_stack2nix}/bin/stack2nix "${stack-project-dir}" --stack-yaml "${stack-yaml}" --hackage-snapshot "${hackageSnapshot}" -o "$OUT_DIR/stack2nix-output.nix" "$@" 1>&2
    nix-store --add "$OUT_DIR/stack2nix-output.nix"
  ''
