# Fully statically linked `stack`

This builds a fully statically linked `stack` executable that should work on any 64-bit Linux distribution.

It uses nix's cross-compilation support to build everything, including `ghc`, against the `musl` libc.

## Building

```
nix-build --no-out-link musl-nixpkgs.nix -A haskellPackages.stack
```

## Building other packages

You can also try to replace `stack` by any other Stackage package that's in the nixpkgs version that I've pinned here.

You may have to patch some dependencies (see `musl-nixpkgs.nix`).

### Binary caches for faster building (optional)

You can use the caches described in `../README.md` for faster building.
