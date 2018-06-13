# static-haskell-nix

This builds an example executable (originally from https://github.com/vaibhavsagar/experiments) with nix,

* creating a fully static executable (`lld` says `not a dynamic executable`)
* to make that possible, it and all dependencies (including ghc) are built against [`musl`](https://www.musl-libc.org/) instead of glibc

Originally inspired by [this comment](https://github.com/NixOS/nixpkgs/pull/37598#issuecomment-375117019).

# Building

```
NIX_PATH=nixpkgs=https://github.com/dtzWill/nixpkgs/archive/7048fc71e325c69ddfa62309c0b661b430774eac.tar.gz nix-build --no-out-link
```

This prints a path that contains the fully linked static executable in the `bin` subdirectory.
