#! /usr/bin/env bash

set -eu -o pipefail

mkdir -p static-stack-test-dir
curl -L https://github.com/commercialhaskell/stack/archive/v2.7.1.tar.gz | tar -xz -C static-stack-test-dir

$(nix-build --no-link -A fullBuildScript --argstr stackDir $PWD/static-stack-test-dir/stack-*)
