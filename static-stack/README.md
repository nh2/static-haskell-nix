# Fully statically linked `stack`

This builds a fully statically linked `stack` executable that should work on any 64-bit Linux distribution.

It uses nix to build everything, including `ghc`, against the `musl` libc.

## Building

```
$(nix-build --no-link -A run-stack2nix-and-static-build-script --argstr stackDir /absolute/path/to/stack/source)
```

We use the `$(nix-build ...)` script approach in order to pin the version of `nix` itself for reproducibility, and because the call to `stack2nix` needs Internet access and thus has to run outside of the nix build sandbox.

## Binary caches for faster building (optional)

You can use the caches described in the [top-level README](../README.md#binary-caches-for-faster-building-optional) for faster building.

## `stack` binaries

Static `stack` binaries I built this way, for download:

* The [official static stack v1.9.3 release](https://github.com/commercialhaskell/stack/releases/tag/v1.9.3) is built using this
* [stack v1.7.1 for 64-bit Linux](https://github.com/nh2/stack/releases/tag/v1.6.5)
* [stack v1.6.5 for 64-bit Linux](https://github.com/nh2/stack/releases/tag/v1.6.5)
