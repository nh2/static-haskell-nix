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
  in
  pkgs.writeScript "stack2nix-build-script.sh" ''
    #!/usr/bin/env bash
    set -eu -o pipefail
    export NIX_PATH=nixpkgs=${pkgs.path}
    export PATH=${pkgs.lib.concatStringsSep ":" add_to_PATH}:$PATH
    OUT_DIR=$(mktemp --directory -t stack2nix-output-dir.XXXXXXXXXX)
    set -x
    ${pkgs.stack2nix}/bin/stack2nix "${stack-project-dir}" --stack-yaml "${stack-yaml}" --hackage-snapshot "${hackageSnapshot}" -o "$OUT_DIR/stack2nix-output.nix" "$@" 1>&2
    nix-store --add "$OUT_DIR/stack2nix-output.nix"
  ''
