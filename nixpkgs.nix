# Detect HerculesCI by checking if NIX_PATH is empty.
# See https://docs.hercules-ci.com/hercules-ci/getting-started/repository/
# If it's empty, we give our custom nixpkgs version;
# otherwise we use what the user has set with NIX_PATH.
if builtins.getEnv "NIX_PATH" == ""
  then
    builtins.trace "NIX_PATH is not set, we're probably in HerculesCI"
      (import (fetchTarball https://github.com/nh2/nixpkgs/archive/a2d7e9b875e8ba7fd15b989cf2d80be4e183dc72.tar.gz) {})
  else
    import <nixpkgs> {}
