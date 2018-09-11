# Fully statically linked `stack`

This builds a fully statically linked `stack` executable that should work on any 64-bit Linux distribution.

It uses nix's cross-compilation support to build everything, including `ghc`, against the `musl` libc.

## Building

```
$(nix-build --no-out-link -A stack2nix-script) /path/to/stack/source
nix-build --no-out-link -A static_stack
```

## Binary caches for faster building (optional)

You can use the caches described in the [top-level README](../README.md#binary-caches-for-faster-building-optional) for faster building.

## `stack` binaries

Static `stack` binaries I built this way, for download:

* [stack v1.6.5 for 64-bit Linux](https://github.com/nh2/stack/releases/tag/v1.6.5)
* [stack v1.7.1 for 64-bit Linux](https://github.com/nh2/stack/releases/tag/v1.7.1)
