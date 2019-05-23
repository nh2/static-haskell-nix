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
}:
  # `stack2nix` requires `cabal` on $PATH.
  # We put our nixpkgs's version of `nix` on $PATH for reproducibility.
  # Everything but `nix-store --add` must print to stderr so that the
  # script prints only the final store path to stdout.
  # The output is generated to a `mktemp --directory` so that parallel
  # invocations don't influence each other.
  pkgs.writeScript "stack2nix-build-script.sh" ''
    #!/usr/bin/env bash
    set -eu -o pipefail
    export NIX_PATH=nixpkgs=${pkgs.path}
    export PATH=${pkgs.cabal-install}/bin:${pkgs.nix}/bin:$PATH
    OUT_DIR=$(mktemp --directory -t stack2nix-output-dir.XXXXXXXXXX)
    set -x
    ${pkgs.stack2nix}/bin/stack2nix "${stack-project-dir}" --hackage-snapshot "${hackageSnapshot}" -o "$OUT_DIR/stack2nix-output.nix" $@ 1>&2
    nix-store --add "$OUT_DIR/stack2nix-output.nix"
  ''
