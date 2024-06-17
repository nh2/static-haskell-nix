[![Funding button](https://opencollective.com/static-haskell-nix/tiers/backer/badge.svg?label=Fund%20this%20project%20on%20OpenCollective.%20Existing%20backers%3A&color=brightgreen)](https://opencollective.com/static-haskell-nix) [![Buildkite build status](https://badge.buildkite.com/4e51728716c0939ac47c5ebd005429c90b8a06fd7e3e15f7d3.svg)](https://buildkite.com/nh2/static-haskell-nix)

# static-haskell-nix

With this repository you can easily build most Haskell programs into fully static Linux executables.

* results are fully static executables (`ldd` says `not a dynamic executable`)
* to make that possible, each exe and all dependencies (including ghc) are built against [`musl`](https://www.musl-libc.org/) instead of glibc

static-haskell-nix can [successfully build > 90% of Stackage executables](https://github.com/nh2/static-haskell-nix/issues/4#issuecomment-406838083), so chances are high it can build yours.

## History

`glibc` encourages dynamic linking to the extent that correct functionality under static linking is somewhere between difficult and bug-ridden.
For this reason, static linking, despite its many advantages (details [here](https://github.com/NixOS/nixpkgs/issues/43795)) has become less and less common.

Due to GHC's dependency on a libc, and many libraries depending on C libraries for which Linux distributions often do not include static library archive files, this situation has resulted in fully static Haskell programs being extremely hard to produce for the common Haskeller, even though the language is generally well-suited for static linking.

This project solves this.

It was inspired by a [blog post by Vaibhav Sagar](https://vaibhavsagar.com/blog/2018/01/03/static-haskell-nix/),
and a [comment by Will Dietz](https://github.com/NixOS/nixpkgs/pull/37598#issuecomment-375117019) about musl.

Work on this so far was sponsored largely by my free time, [FP Complete](https://haskell.fpcomplete.com/) and their clients, and the contributors mentioned [here](https://github.com/NixOS/nixpkgs/issues/43795#issue-342546855).

By now we have a nixpkgs issue on [Fully static Haskell executables](https://github.com/NixOS/nixpkgs/issues/43795) (progress on which is currently this repo, with plans to later merge it into nixpkgs), and [a merged nixpkgs overlay for static nixpkgs in general](https://github.com/NixOS/nixpkgs/pull/48803).

There's also nixpkgs's `pkgsStatic` package set, which can also build many Haskell packages statically with `musl`. Differences are:

* Type of compilation:
  * `pkgsStatic` uses cross-compilation infrastructure, which is inherently more complex, and more difficult to get into.
  * `static-haskell-nix` just replaces the libc, and compiles normally. This allows to build packages that cannot (yet) be cross-compiled.
* `.a` + `.so` files:
  * `pkgsStatic` does _exclusively_ static builds, it generates only `.a` files and no `.so` files.
  * `static-haskell-nix` generates both `.a` and `.so` files, which allows more intermediate software to run (e.g. some build systems using Python libraries doing `dlopen()` on some `.so` files).
  * In the past, this made a big difference for TemplateHaskell, which worked well only when `.so` files are present. This seems to have improved. `static-haskell-nix` now has an off-by-default flag `useArchiveFilesForTemplateHaskell` that users are encouraged to test.
* Hacky fixes:
  * `static-haskell-nix` contains a large amount of per-package fixes for static builds for which we haven't found a way to integrate them cleanly into nixpkgs yet.
* Pinning:
  * `static-haskell-nix` does not impede nixpkgs progress, as it is maintained out of the nixkpgs.

In general, any contribution to `static-haskell-nix` or `pkgsStatic` benefits the respective other one.

A goal is to shrink `static-haskell-nix` over time, moving those parts into nixpkgs that do not slow down nixpkgs's fast pace.

## Funding

You can support this project financially [on OpenCollective](https://opencollective.com/static-haskell-nix). Goals:

* [x] **Dedicated build server** - [Goal reached!](https://opencollective.com/static-haskell-nix/updates/build-server-funding-goal-reached) Thanks to our awesome [contributors](https://opencollective.com/static-haskell-nix#contributors)!

  The first and main goal is to get to ~28 EUR/month to buy a cheap Hetzner dedicated build server for fast CI and pushing to Cachix. It will also allow anybody to download almost any executable on Stackage pre-built as a static binary, so that people can try out Haskell programs easily without having to install lots of dependencies.

  Because the server is so cheap, already 1 or 2 EUR/month will bring us to that goal quickly.

[<img src="https://hercules-ci.com/images/logo/hercules.png" height="24" title="Hercules CI" alt="Hercules CI Logo">](https://hercules-ci.com)
The **storage infrastructure** ([Cachix](https://cachix.org)) for downloading pre-built packages is **sponsored by the [awesome guys](https://hercules-ci.com/#about) from Hercules CI**.
They are building a nix-based CI service you can safely run on your own infrastructure. _static-haskell-nix_ also uses it.
<br />If your company or project needs that, check [**Hercules CI**](https://hercules-ci.com) out!

## Testing

We have multiple CIs:

* [HerculesCI](https://hercules-ci.com/github/nh2/static-haskell-nix/): Builds with pinned nixpkgs.
  Publicly visible, but requires free sign-in. Click the most recent job to which 100s of binaries we build.
* [BuildKite](https://buildkite.com/nh2/static-haskell-nix/):
  * Builds with pinned nixpkgs (submodule): Should always be green.
  * Builds with latest nixpkgs `unstable`, daily: Shows up as **Scheduled build**.
    May break when nixpkgs upstream changes.

## Binary caches for faster building (optional)

Install [cachix](https://static-haskell-nix.cachix.org/) and run `cachix use static-haskell-nix` before your `nix-build`.

If you get a warning during `cachix use`, read [this](https://github.com/cachix/cachix/issues/56#issuecomment-423820198).

If you don't want to install `cachix` for some reason or `cachix use` doesn't work, you should also be able to manually set up your `nix.conf` (e.g. in `$HOME/.config/nix/nix.conf`; you may have to create the file) to have contents like this:

```
extra-substituters = http://static-haskell-nix-ci.nh2.me:5000 https://cache.nixos.org https://static-haskell-nix.cachix.org
extra-trusted-public-keys = static-haskell-nix-ci-cache-key:Z7ZpqYFHVs467ctsqZADpjQ/XkSHx6pm5XBZ4KZW3/w= static-haskell-nix.cachix.org-1:Q17HawmAwaM1/BfIxaEDKAxwTOyRVhPG5Ji9K3+FvUU=
```

or append to command lines:

```sh
--option extra-substituters 'http://static-haskell-nix-ci.nh2.me:5000' --option extra-trusted-public-keys 'static-haskell-nix-ci-cache-key:Z7ZpqYFHVs467ctsqZADpjQ/XkSHx6pm5XBZ4KZW3/w='
```

Note that you may not get cached results if you use a different `nix` version than I used to produce the cache (I used `2.0.4` as of writing, which you can get from [here](https://nixos.org/releases/nix/nix-2.0.4/install)).

## Building arbitrary packages

The [`survey/default.nix`](./survey/default.nix) was originally a survey of Haskell executables that are known to (and known _not_ to) work with this approach, however it also exposes packages sets with overridden Haskell packages and dependencies that you can use to build _your own_ packages. The name `survey` shouldn't put you off from using it.

If you are a nix user, you can `import` this functionality and override the `haskellPackages` to include your own package, for example in the [PostgREST project](https://github.com/PostgREST/postgrest/blob/main/nix/static-haskell-package.nix).

### Structure of `survey/default.nix`

The process of building up to the final `haskellPackages` is broken down into multiple steps, with the intermediate package sets also exposed for your use.

We start with a plain nixpkgs named `normalPkgs`, defaulting to the version provided by [`nixpkgs.nix`](./nixpkgs.nix), but you can pass in your own version here.
You could instead provide `overlays`, which get applied to `normalPkgs`.
The `.pkgsMusl` from `normalPkgs` now forms our base `pkgs`.

Packages in `pkgsMusl` typically [only include `.so` files](https://github.com/NixOS/nixpkgs/issues/61575), but not `.a` files. We create a `archiveFilesOverlay`, which overrides our Haskell dependencies (i.e. C libraries) to include `.a` files as well. 
This usually involves low-level library specific actions, but the goal is to upstream these to nixpkgs under a `dontDisableStatic` attribute.
We apply this overlay to `pkgs` to get `pkgsWithArchiveFiles`.

This package set _may_ be sufficient for your needs if you have a separate build system (e.g. Bazel) and are only after a statically linked GHC and library dependencies.

The next step is to configure Hackage library packages to use static linking. This is done by the `haskellLibsReadyForStaticLinkingOverlay` to produce `pkgsWithHaskellLibsReadyForStaticLinking`.
TODO: Document what `addStaticLinkerFlagsWithPkgconfig` does.

Finally `staticHaskellBinariesOverlay` infers which haskell packages are binaries, and overrides them using the `statify` function, which primarily sets the `--enable-executable-static` Cabal flag.
This produces `pkgsWithStaticHaskellBinaries`, which is where the `haskellPackages` attribute set is taken from.

### Building existing packages in the survey

To build existing packages, run:

```
NIX_PATH=nixpkgs=nixpkgs nix-build --no-link survey/default.nix -A working
```

Relevant package sets available in the survey include (select via `-A`):

* `working` -- build all exes known to be working
* `notWorking` -- build all exes known to be not working (help welcome to make them work)
* `haskellPackages.somePackage` -- build a specific package from our overridden package set

## Building a minimal example (don't use this in practice)

`default.nix` builds an example executable (originally from https://github.com/vaibhavsagar/experiments). Run:

```
NIX_PATH=nixpkgs=nixpkgs nix-build --no-link
```

This prints a path that contains the fully linked static executable in the `bin` subdirectory.

This example is so that you get the general idea.
In practice, you probably want to use one of the approaches from the "Building arbitrary packages" or "Building stack projects" sections below.

## Building `stack` projects

The [`static-stack2nix-builder-example`](./static-stack2nix-builder-example) directory shows how to build any `stack`-based project statically.

Until Stack 2.3, the official static build of `stack` itself was built using this method (Stack >= 2.3 static builds are built in an Alpine Docker image after GHC on Alpine started working again, see [here](https://github.com/commercialhaskell/stack/pull/5267)).
The [`static-stack`](./static-stack) directory shows how Stack itself can be built statically with static-haskell-nix.
`stack` is a big package with many dependencies, demonstrating that it works also for large projects.

## Related important open issues

You can contribute to these to help static Haskell executables:

* https://github.com/haskell/cabal/issues/8455

## FAQ

* I get `cannot find section .dynamic`. Is this an error?
  * No, this is an informational message printed by `patchelf`. If your final looks like
    ```
    ...
    cannot find section .dynamic
    /nix/store/dax3wjbjfrcwj6r3mafxj5fx6wcg5zbp-stack-2.3.0.1
    ```
    then `/nix/store/dax3wjbjfrcwj6r3mafxj5fx6wcg5zbp-stack-2.3.0.1` is your final output _store path_ whose `/bin` directory contains your static executable.
* I get `stack2nix: user error (No such package mypackage-1.2.3 in the cabal database. Did you run cabal update?)`.
  * You most likely have to bump the date like `hackageSnapshot = "2019-05-08T00:00:00Z";` to a newer date (past the time that package-version was added to Hackage).
* I get a linker error.
  What's a good way to investigate what the linker invocation is?
  * Pass `-v` to Cabal, and to GHC itself:
    ```sh
    nix-build --expr '(import ./survey/default.nix {}).haskellPackages.YOURPACKAGE.overrideAttrs (old: { configureFlags = (old.configureFlags or []) ++ ["-v" "--ghc-options=-v"]; })'
    ```
    Look for `*** Linker:` in the GHC output.
* Can I build Stack projects with resolvers that are too old to be supported by Stack >= 2?
  * No. For that you need need to use an old `static-haskell-nix` version: The one before [this PR](https://github.com/nh2/static-haskell-nix/pull/98) was merged.
* I get some other error. Can I just file an issue and have you help me with it?
  * Yes. If possible (especially if your project is open source), please push some code so that your issue can be easily reproduced.


## Open questions

* Nixpkgs issue [Provide middle-ground overlay between pkgsMusl and pkgsStatic](https://github.com/NixOS/nixpkgs/issues/61575):

  Should nixpkgs provide a `makeStaticAndSharedLibraries` adapter to provide a package set?
  That might be better (but more difficult) than what we do now, with `dontDisableStaticOverlay`, because:
  * `dontDisableStatic` is to prevent `--disable-static` to autoconf, which is really specific to C + autoconf.
    A package set should do more than that, also for Meson, CMake, etc.
  `nh2` started implementing this idea in nixpkgs branch `static-haskell-nix-nixos-24.05-makeStaticAndSharedLibraries`.

* Can we avoid building bootstrap tools?
  * Our current overlays also build `xgcc`, `gcc`, `binutils`, and so on.
  * This is because we override all packages to have e.g. `.a` files, and some of those are also dependencies of e.g. `gcc`.
  * `pkgsStatic` avoids that by being a `cross` toolchain.
    * But might this cause additional issues?
      Because `cross` may have additional complexities when building the actual packages we're interested in, vs just switching the libc ("native" compilation)?
      Unclear.
  * For now, we accept those additional builds.

* How should we handle `pkg-config` regarding static dependencies?

  E.g. `libtiff` depends on `lerc` and `libtiff-4.pc` correctly declares

  ```
  Libs.private: -llzma -lLerc -ljpeg -ldeflate -lz -lm
  Requires.private: liblzma libjpeg libdeflate zlib
  ```

  But the `.pc` file does not include the path on which `libLerc.a` can be found, nor does anything in nixpkgs set `PKG_CONFIG_PATH` such that `Lerc.pc` is on it.
  Thus, linking a static binary that uses `libtiff-4.pc` fails with

  ```
  cannot find -lLerc: No such file or directory
  ```

  * Should we use `propagatedBuildInputs` for this?
    * Yes! We can use `stdenvAdapters.propagateBuildInputs`.
      * Current problem: Using that in a native compilation (instead of cross as `pkgsMusl` does) causes:
        ```
        error: build of '/nix/store/...-stdenv-linux.drv' failed: output '/nix/store/...-stdenv-linux' is not allowed to refer to the following paths:
                /nix/store/...-binutils-patchelfed-ld-wrapper-2.41
                /nix/store/...-pcre2-10.43-dev
                /nix/store/...-gmp-with-cxx-6.3.0-dev
                /nix/store/...-musl-iconv-1.2.3
                /nix/store/...-binutils-2.41
                /nix/store/...-bootstrap-tools
        ```
        * John Ericson explained that the bootstrap rebuild avoidance (mentioned in a point above) also solves this issue for `pkgsStatic`.
          So we probably need to do something similar.
  * After fixing that, we still need to fix `libtiff` to include `lerc` in `Requires.private`.
    * Done in https://github.com/NixOS/nixpkgs/pull/320105
