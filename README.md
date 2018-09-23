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

Install [cachix](https://cachix.org) and run `cachix use static-haskell-nix` before your `nix-build`.

If you get a warning during `cachix use`, read [this](https://github.com/cachix/cachix/issues/56#issuecomment-423820198).

If you don't want to install `cachix` for some reason or `cachix use` doesn't work, you should also be able to manually set up your `nix.conf` to have contents like this:

```
substituters = https://cache.nixos.org https://static-haskell-nix.cachix.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= static-haskell-nix.cachix.org-1:Q17HawmAwaM1/BfIxaEDKAxwTOyRVhPG5Ji9K3+FvUU=
```

Note that you may not get cached results if you use a different `nix` version than I used to produce the cache (I used `2.0.4` as of writing, which you can get from [here](https://nixos.org/releases/nix/nix-2.0.4/install)).

## Building arbitrary packages

The [`static-stack`](./static-stack) directory shows how to build a fully static `stack` executable (a Haskell package with many dependencies), and makes it reasonably easy to build other packages as well.

The [`survey`](./survey) directory maintains a select set of Haskell executables that are known and not known to work with this approach; contributions are welcome to grow the set of working executables.
Run for example:

```
NIX_PATH=nixpkgs=https://github.com/NixOS/nixpkgs/archive/88ae8f7d.tar.gz nix-build --no-link survey/default.nix -A working
```

There are multiple package sets available in the survey (select via `-A`):

* `working` -- build all exes known to be working
* `notWorking` -- build all exes known to be not working (help welcome to make them work)
* `haskellPackages.somePackage` -- build a specific package from our overridden package set
