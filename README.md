# static-haskell-nix

This builds an example executable (originally from https://github.com/vaibhavsagar/experiments) with nix,

* creating a fully static executable (`ldd` says `not a dynamic executable`)
* to make that possible, it and all dependencies (including ghc) are built against [`musl`](https://www.musl-libc.org/) instead of glibc

Originally inspired by [this comment](https://github.com/NixOS/nixpkgs/pull/37598#issuecomment-375117019).

## Building

```
NIX_PATH=nixpkgs=https://github.com/dtzWill/nixpkgs/archive/7048fc71e325c69ddfa62309c0b661b430774eac.tar.gz nix-build --no-out-link
```

This prints a path that contains the fully linked static executable in the `bin` subdirectory.

### Binary caches for faster building (optional)

#### On non-NixOS

You can use the binary cache shown in [here](https://github.com/NixOS/nixpkgs/pull/34645) to not have to build lots of native dependencies against `musl`,
and you can use my binary nix closure mentioned [here](https://github.com/NixOS/nixpkgs/pull/37598#issuecomment-396760267) to not have to build GHC.

#### On NixOS

Install [cachix](https://cachix.org) and run `cachix use static-haskell-nix` before your `nix-build`.

## Building arbitrary packages

The [`static-stack`](./static-stack) directory shows how to build a fully static `stack` executable (a Haskell package with many dependencies), and makes it reasonably easy to build other packages as well.
