# static-haskell-nix

This builds an example executable (originally from https://github.com/vaibhavsagar/experiments) with nix,

* creating a fully static executable (`ldd` says `not a dynamic executable`)
* to make that possible, it and all dependencies (including ghc) are built against [`musl`](https://www.musl-libc.org/) instead of glibc

Originally inspired by [this comment](https://github.com/NixOS/nixpkgs/pull/37598#issuecomment-375117019).

## Building

```
NIX_PATH=nixpkgs=https://github.com/NixOS/nixpkgs/archive/2c07921cff84dfb0b9e0f6c2d10ee2bfee6a85ac.tar.gz nix-build --no-out-link
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

The [`survey`](./survey) directory maintains a select set of Haskell executables that are known and not known to work with this approach; contributions are welcome to grow the set of working executables.
Run for example:

```
NIX_PATH=nixpkgs=https://github.com/NixOS/nixpkgs/archive/2c07921cff84dfb0b9e0f6c2d10ee2bfee6a85ac.tar.gz nix-build --no-link survey/default.nix -A working
```

There are multiple package sets available in the survey (select via `-A`):

* `working` -- build all exes known to be working
* `notWorking` -- build all exes known to be not working (help welcome to make them work)
* `haskellPackages.somePackage` -- build a specific package from our overridden package set
