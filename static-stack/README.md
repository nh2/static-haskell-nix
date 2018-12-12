# Fully statically linked `stack`

This builds a fully statically linked `stack` executable that should work on any 64-bit Linux distribution.

It uses nix's cross-compilation support to build everything, including `ghc`, against the `musl` libc.

## Building

```
$(nix-build --no-out-link -A stack2nix-script) /path/to/stack/source
$(nix-build --no-out-link -A build-script)
```

We use the `$(nix-build ...)` script approach in order to pin the version of `nix` itself for reproducibility.

## Binary caches for faster building (optional)

You can use the caches described in the [top-level README](../README.md#binary-caches-for-faster-building-optional) for faster building.

## `stack` binaries

Static `stack` binaries I built this way, for download:

* The [official stack v1.9.3 release](https://github.com/commercialhaskell/stack/releases/tag/v1.9.3) is built using this
* [stack v1.7.1 for 64-bit Linux](https://github.com/nh2/stack/releases/tag/v1.6.5)
* [stack v1.6.5 for 64-bit Linux](https://github.com/nh2/stack/releases/tag/v1.6.5)
