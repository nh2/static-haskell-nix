let
  tracing = false; # Enable this to see debug traces

  # TODO: Remove when
  #   * https://github.com/NixOS/cabal2nix/pull/360
  #   * https://github.com/NixOS/cabal2nix/commit/7ccbd668d1f9f8154a1fbc1ba48d7a483f37a2a7
  # are merged and available
  cabal2nix-fix-overlay = pkgs: final: previous:
    with final.haskell.lib; {
      haskellPackages = previous.haskellPackages.override (old: {
        overrides = final.lib.composeExtensions (old.overrides or (_: _: {})) (

          self: super: {
            cabal2nix = overrideCabal super.cabal2nix (old: {
              src = pkgs.fetchFromGitHub {
                owner = "nh2";
                repo = "cabal2nix";
                rev = "4080fbca34278fc099139e7fcd3164ded8fe86c1";
                sha256 = "1dp6cmqld6ylyq2hjfpz1n2sz91932fji879ly6c9sri512gmnbx";
              };
            });

          }
        );
      });
    };

  trace = message: value:
    if tracing then builtins.trace message value else value;

in

{
  normalPkgs ? (import <nixpkgs> {}),

  pkgs ? (import normalPkgs.path {
    config.allowUnfree = true;
    config.allowBroken = true;
    # config.permittedInsecurePackages = [
    #   "webkitgtk-2.4.11"
    # ];
    overlays = [ (cabal2nix-fix-overlay normalPkgs) ];
  }).pkgsMusl,

  compiler ? "ghc843",

  normalHaskellPackages ?
    if integer-simple
      # Note we don't have to set the `-finteger-simple` flag for packages that GHC
      # depends on (e.g. text), because nix + GHC already do this for us:
      #   https://github.com/ghc/ghc/blob/ghc-8.4.3-release/ghc.mk#L620-L626
      #   https://github.com/peterhoeg/nixpkgs/commit/50050f3cc9e006daa6800f15a29e258c6e6fa4b3#diff-2f6f8fd152c14d37ebd849aa6382257aR35
      then pkgs.haskell.packages.integer-simple."${compiler}"
      else pkgs.haskell.packages."${compiler}",

  integer-simple ? false,
}:

let

  lib = pkgs.lib;

  # Function that tells us if a given Haskell package has an executable.
  isExecutable = pkg:
    (pkgs.haskell.lib.overrideCabal pkg (drv: {
      passthru.isExecutable = drv.isExecutable or false;
    })).isExecutable;

  # Function that tells us if a given Haskell package is marked as broken.
  isBroken = pkg: pkg.meta.broken or false;

  # Function that for a given Haskell package tells us if any of
  # its dependencies is marked as `broken`.
  hasBrokenDeps = pkg:
    let
      libraryDepends =
        (pkgs.haskell.lib.overrideCabal pkg (drv: {
          passthru.libraryHaskellDepends = drv.libraryHaskellDepends or [];
        })).libraryHaskellDepends;
    in
      lib.any (x:
        let
          res = builtins.tryEval (lib.isDerivation x && x ? env && isBroken x);
          broken = res.success && res.value;
        in
          if broken
            then trace "broken because of broken deps: ${pkg}" broken
            else broken
      ) libraryDepends;

  # Nixpkgs contains both Hackage and Stackage packages.
  # We want to build only executables that are on Stackage because
  # we know that those should build.
  # Find all Stackage package names here so we can use them
  # as a filter.
  # Done by parsing the configuration file that contains
  # which packages come from Stackage.
  # Contains a list of package names (strings).
  stackagePackages =
    let
      stackageInfoPath = pkgs.path + "/nixpkgs/pkgs/development/haskell-modules/configuration-hackage2nix.yaml";
      pythonWithYaml = pkgs.python2Packages.python.withPackages (pkgs: [pkgs.pyyaml]);
      dont-distribute-packages-file = normalPkgs.runCommand "test" {} ''
        ${pythonWithYaml}/bin/python -c 'import yaml, json; x = yaml.load(open("${stackageInfoPath}")); print(json.dumps([line.split(" ")[0] for line in x["default-package-overrides"]]))' > $out
      '';
      dont-distribute-packages = builtins.fromJSON (builtins.readFile dont-distribute-packages-file);
    in
      dont-distribute-packages;

  # Turns a list into a "set" (map where all keys are {}).
  keySet = list: builtins.listToAttrs (map (name: lib.nameValuePair name {}) list);

  # Making it a set for faster lookup
  stackagePackagesSet = keySet stackagePackages;
  isStackagePackage = name: builtins.hasAttr name stackagePackagesSet;

  stackageCommit = "8832644c5601994e27f4c5a0d986941c85b52abc";
  stackage-build-constraints-yaml = pkgs.fetchurl {
    # Needs to be updated when nixpkgs updates the Stackage LTS from which packages come.
    # But we use it only for the blacklist so keeping it tightly up to date is not so critical.
    url = "https://raw.githubusercontent.com/commercialhaskell/stackage/${stackageCommit}/build-constraints.yaml";
    sha256 = "1g9w1bicjbji52zjkspa9vqw0ghy8zm59wcmrb53iz87h23c0qkh";
  };
  # The Stackage `build-constraints.yaml` filed as a nix value.
  stackage-build-constraints =
    let
      pythonWithYaml = pkgs.python2Packages.python.withPackages (pkgs: [pkgs.pyyaml]);
      # We remove the "packages" key because that one has all the author names,
      # which contain unicode escapes, which `builtins.fromJSON` cannot handle
      # (as of nix 2.0.4).
      build-constraints-json-file = normalPkgs.runCommand "stackage-build-constraints-${stackageCommit}.json" {} ''
        ${pythonWithYaml}/bin/python -c 'import yaml, json; x = yaml.load(open("${stackage-build-constraints-yaml}")); del x["packages"]; print(json.dumps(x))' > $out
      '';
    in
      builtins.fromJSON (builtins.readFile build-constraints-json-file);

  # A `haskellPackages` set in which tests are skipped (`dontCheck`) for
  # all packages that are marked as failing their tests on Stackage
  # or known for failing their tests for other reasons.
  # Note this may disable more tests than necessary because some packages'
  # tests may work fine in nix when they don't work on Stackage,
  # for example due to more system dependencies being available.
  haskellPackagesWithFailingStackageTestsDisabled = with pkgs.haskell.lib; normalHaskellPackages.override (old: {
    overrides = pkgs.lib.composeExtensions (old.overrides or (_: _: {})) (self: super:
      let
        # This map contains the package names that we don't want to run tests on,
        # either because they fail on Stackage or because they fail for us
        # with specific reasons given.
        skipTestPackageNames =
          stackage-build-constraints.expected-test-failures ++
          stackage-build-constraints.skipped-tests ++
          [
            # Tests don't pass on local checkout either (checked on ef3e203e9578)
            # because its own executable is not in PATH ("ghc: could not execute: doctest-driver-gen")
            "doctest-driver-gen"
            # https://github.com/ekmett/ad/issues/73 (floating point precision)
            "ad"
          ];
        # Making it a set for faster lookup
        failuresSet = keySet skipTestPackageNames;
        isFailure = name: builtins.hasAttr name failuresSet;

        packagesWithTestsToDisable =
          lib.filterAttrs (name: value:
            if isFailure name
              then
                trace "disabling tests (because it is in skipTestPackageNames) for ${name}"
                  true
              else false
          ) super;
        packagesWithTestsDisabled =
          lib.mapAttrs (name: value:
            # We have to do a null check because some builtin packages like
            # `text` seem to have just `null` as a value. Not sure why that is.
            (if value != null then dontCheck value else value)
          ) packagesWithTestsToDisable;
        numPackagesTestsDisabled = lib.length (builtins.attrNames packagesWithTestsDisabled);
      in
        trace "Disabled tests for ${toString numPackagesTestsDisabled} packages"
          packagesWithTestsDisabled
    );
  });


  # Stackage package names we want to blacklist.
  blacklist = [
    # Doens't build in `normalPkgs.haskellPackages` either
    "mercury-api"
  ];

  # All Stackage executables who (and whose dependencies) are not marked
  # as broken in nixpkgs.
  # This is a subset of a `haskellPackages` package set.
  stackageExecutables =
    let
      stackageExecutables = lib.filterAttrs (name: x: isStackagePackage name && !(lib.elem name blacklist) && (
        let
          res = builtins.tryEval (
               lib.isDerivation x
            && x ? env
            && isExecutable x
            && !(isBroken x)
            && !(hasBrokenDeps x)
          );
        in
          res.success && res.value)
      ) normalHaskellPackages;

    stackageExecutablesNames = builtins.attrNames stackageExecutables;
    nMany = lib.length stackageExecutablesNames;
    in
      trace
        ("selected stackage executables:\n"
          + lib.concatStringsSep "\n" stackageExecutablesNames
          + "\n---\n${toString nMany} Stackage executables total"
        )
        stackageExecutables;

  # Making it a set for faster lookup
  stackageExecutablesSet = keySet (builtins.attrNames stackageExecutables);
  isStackageExecutable = name: builtins.hasAttr name stackageExecutablesSet;


  # Cherry-picking cabal fixes

  # TODO Remove this when these fixes are available in nixpkgs:
  #   https://github.com/haskell/cabal/pull/5356 (-L flag deduplication)
  #   https://github.com/haskell/cabal/pull/5446 (--enable-executable-static)
  #   https://github.com/haskell/cabal/pull/5451 (ld-option passthrough)

  # TODO do this via patches instead
  cabal_patched_src = pkgs.fetchFromGitHub {
    owner = "nh2";
    repo = "cabal";
    rev = "b66be72db3b34ea63144b45fcaf61822e0fade87";
    sha256 = "030f785a60fv0h6yqb6fmz1092nwczd0dbvnnsn6gvjs22rj39hc";
  };

  Cabal_patched_Cabal_subdir = pkgs.stdenv.mkDerivation {
    name = "cabal-dedupe-src";
    buildCommand = ''
      cp -rv ${cabal_patched_src}/Cabal/ $out
    '';
  };

  Cabal_patched = normalHaskellPackages.callCabal2nix "Cabal" Cabal_patched_Cabal_subdir {};

  useFixedCabal = drv: pkgs.haskell.lib.overrideCabal drv (old: {
    setupHaskellDepends = (if old ? setupHaskellDepends then old.setupHaskellDepends else []) ++ [ Cabal_patched ];
    # TODO Check if this is necessary
    libraryHaskellDepends = (if old ? libraryHaskellDepends then old.libraryHaskellDepends else []) ++ [ Cabal_patched ];
  });


  # Overriding system libraries that don't provide static libs
  # (`.a` files) by default

  sqlite_static = pkgs.sqlite.overrideAttrs (old: { dontDisableStatic = true; });

  lzma_static = pkgs.lzma.overrideAttrs (old: { dontDisableStatic = true; });

  postgresql_static = pkgs.postgresql.overrideAttrs (old: { dontDisableStatic = true; });

  pcre_static = pkgs.pcre.overrideAttrs (old: { dontDisableStatic = true; });

  expat_static = pkgs.expat.overrideAttrs (old: { dontDisableStatic = true; });

  mpfr_static = pkgs.mpfr.overrideAttrs (old: { dontDisableStatic = true; });

  gmp_static = pkgs.gmp.overrideAttrs (old: { dontDisableStatic = true; });

  libxml2_static = pkgs.libxml2.overrideAttrs (old: { dontDisableStatic = true; });

  nettle_static = pkgs.nettle.overrideAttrs (old: { dontDisableStatic = true; });

  bzip2_static = pkgs.bzip2.overrideAttrs (old: { dontDisableStatic = true; });

  nghttp2_static = pkgs.nghttp2.overrideAttrs (old: { dontDisableStatic = true; });

  libssh2_static = pkgs.libssh2.overrideAttrs (old: { dontDisableStatic = true; });

  # Requires https://github.com/NixOS/nixpkgs/pull/43870
  # TODO Remove the above note when it's merged and available
  # Note krb5 does not support building both static and shared at the same time.
  krb5_static = pkgs.krb5.override { staticOnly = true; };

  # Requires https://github.com/NixOS/nixpkgs/pull/43870
  # TODO Remove the above note when it's merged and available
  openssl_static = pkgs.openssl.override { static = true; };

  curl_static = (pkgs.curl.override {
    nghttp2 = nghttp2_static;
    zlib = pkgs.zlib.static;
    libssh2 = libssh2_static;
    kerberos = krb5_static;
    openssl = openssl_static;
  }).overrideAttrs (old: {
    dontDisableStatic = true;
    nativeBuildInputs = old.nativeBuildInputs ++ [
      # pkgs.zlib.static above does not contain the header files
      # (so curl would disable zlib support), so we have to give
      # the normal zlib package manually.
      # Note curl doesn't fail hard when we forget to give this, it only warns:
      #   https://github.com/curl/curl/blob/7bc11804374/configure.ac#L954
      pkgs.zlib
    ];
    configureFlags = old.configureFlags ++ [
      # When linking krb5 statically, one has to pass -lkrb5support explicitly
      # because core functions such as `k5_clear_error` are in
      # `libkrb5support.a` and not in `libkrb5.a`.
      # See https://stackoverflow.com/questions/39960588/gcc-linking-with-kerberos-for-compiling-with-curl-statically/41822755#41822755
      "LIBS=-lkrb5support"
    ];
  });


  # Overriding `haskellPackages` to fix *libraries* so that
  # they can be used in statically linked binaries.
  haskellPackagesWithLibsReadyForStaticLinking = with pkgs.haskell.lib; haskellPackagesWithFailingStackageTestsDisabled.override (old: {
    overrides = pkgs.lib.composeExtensions (old.overrides or (_: _: {})) (self: super:
    let
      addStaticLinkerFlagsWithPkgconfig = haskellDrv: pkgConfigNixPackages: pkgconfigFlagsString:
        overrideCabal (appendConfigureFlag haskellDrv [
          # Ugly alert: We use `--start-group` to work around the fact that
          # the linker processes `-l` flags in the order they are given,
          # so order matters, see
          #   https://stackoverflow.com/questions/11893996/why-does-the-order-of-l-option-in-gcc-matter
          # and GHC inserts these flags too early, that is in our case, before
          # the `-lcurl` that pulls in these dependencies; see
          #   https://github.com/haskell/cabal/pull/5451#issuecomment-406759839
          "--ld-option=--start-group"
        ]) (old: {
          # We can't pass all linker flags in one go as `ld-options` because
          # the generic Haskell builder doesn't let us pass flags containing spaces.
          preConfigure = builtins.concatStringsSep "\n" [
            (old.preConfigure or "")
            ''
              configureFlags+=$(for flag in $(pkg-config --static ${pkgconfigFlagsString}); do echo -n " --ld-option=$flag"; done)
            ''
          ];
          # TODO Somehow change nixpkgs (the generic haskell builder?) so that
          # putting `curl_static` into `libraryPkgconfigDepends` is enough
          # and the manual modification of `configureFlags` is not necessary.
          libraryPkgconfigDepends = (old.libraryPkgconfigDepends or []) ++ pkgConfigNixPackages;
        });
    in {

      # Helpers for other packages

      hpc-coveralls = appendPatch super.hpc-coveralls (builtins.fetchurl https://github.com/guillaume-nargeot/hpc-coveralls/pull/73/commits/344217f513b7adfb9037f73026f5d928be98d07f.patch);
      persistent-sqlite = super.persistent-sqlite.override { sqlite = sqlite_static; };
      lzma = super.lzma.override { lzma = lzma_static; };

      # If we `useFixedCabal` on stack, we also need to use the
      # it on hpack and hackage-security because otherwise
      # stack depends on 2 different versions of Cabal.
      hpack = useFixedCabal super.hpack;
      hackage-security = useFixedCabal super.hackage-security;

      # See https://github.com/hslua/hslua/issues/67
      # It's not clear if it's safe to disable this as key functionality may be broken
      hslua = dontCheck super.hslua;

      hsyslog = useFixedCabal super.hsyslog;

      # Without this, when compiling `hsyslog`, GHC sees 2 Cabal
      # libraries, the unfixed one provided by cabal-doctest
      # (which is GHC's global unfixed one), and the fixed one as declared
      # for `hsyslog` through statify.
      # GHC does NOT issue a warning in that case, but just silently
      # picks the one from the global package database (the one
      # cabal-doctest would want), instead of the one from our
      # `useFixedCabal` one which is given on the command line at
      #   https://github.com/NixOS/nixpkgs/blob/e7e5aaa0b9/pkgs/development/haskell-modules/generic-builder.nix#L330
      cabal-doctest = useFixedCabal super.cabal-doctest;

      darcs =
        addStaticLinkerFlagsWithPkgconfig
          (super.darcs.override { curl = curl_static; })
          [ curl_static ]
          # Ideally we'd like to use
          #   pkg-config --static --libs libcurl
          # but that doesn't work because that output contains `-Wl,...` flags
          # which aren't accepted by `ld` and thus cannot be passed as `ld-option`s.
          # See https://github.com/curl/curl/issues/2775 for an investigation of why.
          "--libs-only-l libcurl";

      postgresql-libpq = super.postgresql-libpq.override { postgresql = postgresql_static; };

      # TODO For the below packages, it would be better if we could somehow make all users
      # of postgresql-libpq link in openssl via pkgconfig.
      postgresql-schema =
        addStaticLinkerFlagsWithPkgconfig
          super.postgresql-schema
          [ openssl_static ]
          "--libs openssl";
      postgresql-simple-migration =
        addStaticLinkerFlagsWithPkgconfig
          super.postgresql-simple-migration
          [ openssl_static ]
          "--libs openssl";
      squeal-postgresql =
        addStaticLinkerFlagsWithPkgconfig
          super.squeal-postgresql
          [ openssl_static ]
          "--libs openssl";

      snap-server =
        addStaticLinkerFlagsWithPkgconfig
          super.snap-server
          [ openssl_static ]
          "--libs openssl";

      moesocks =
        addStaticLinkerFlagsWithPkgconfig
          super.moesocks
          [ openssl_static ]
          "--libs openssl";

      microformats2-parser =
        addStaticLinkerFlagsWithPkgconfig
          super.microformats2-parser
          [ pcre_static ]
          "--libs pcre";

      highlighting-kate =
        addStaticLinkerFlagsWithPkgconfig
          super.highlighting-kate
          [ pcre_static ]
          "--libs pcre";

      file-modules =
        addStaticLinkerFlagsWithPkgconfig
          super.file-modules
          [ pcre_static ]
          "--libs pcre";

      ghc-core =
        addStaticLinkerFlagsWithPkgconfig
          super.ghc-core
          [ pcre_static ]
          "--libs pcre";

      xml-to-json =
        addStaticLinkerFlagsWithPkgconfig
          super.xml-to-json
          [ curl_static expat_static ]
          # Ideally we'd like to use
          #   pkg-config --static --libs libcurl
          # but that doesn't work because that output contains `-Wl,...` flags
          # which aren't accepted by `ld` and thus cannot be passed as `ld-option`s.
          # See https://github.com/curl/curl/issues/2775 for an investigation of why.
          "--libs-only-l libcurl expat";

      aern2-real =
        addStaticLinkerFlagsWithPkgconfig
          super.aern2-real
          [ mpfr_static gmp_static ]
          "--libs mpfr gmp";

      credential-store =
        addStaticLinkerFlagsWithPkgconfig
          super.credential-store
          [ libxml2_static ]
          "--libs xml";

      hopenpgp-tools =
        addStaticLinkerFlagsWithPkgconfig
          super.hopenpgp-tools
          [ nettle_static bzip2_static ]
          "--libs nettle bz2";

      # TODO Remove when https://github.com/NixOS/cabal2nix/issues/372 is fixed and available
      yaml = disableCabalFlag super.yaml "system-libyaml";

      stack = enableCabalFlag super.stack "disable-git-info";

      cryptonite =
        if integer-simple
          then disableCabalFlag super.cryptonite "integer-gmp"
          else super.cryptonite;

      # The test-suite `test-scientific`'s loops forver on 100% CPU with integer-simple
      # TODO Ask Bas about it
      scientific =
        if integer-simple
          then dontCheck super.scientific
          else super.scientific;
      # The test-suite `test-x509-validation`'s loops forver on 100% CPU with integer-simple
      x509-validation =
        if integer-simple
          then dontCheck super.x509-validation
          else super.x509-validation;
    });

  });

  statify = drv: with pkgs.haskell.lib; pkgs.lib.foldl appendConfigureFlag (disableLibraryProfiling (disableSharedExecutables (useFixedCabal drv))) [
    # "--ghc-option=-fPIC"
    "--enable-executable-static" # requires `useFixedCabal`
    "--extra-lib-dirs=${pkgs.gmp6.override { withStatic = true; }}/lib"
    # TODO These probably shouldn't be here but only for packages that actually need them
    "--extra-lib-dirs=${pkgs.zlib.static}/lib"
    "--extra-lib-dirs=${pkgs.ncurses.override { enableStatic = true; }}/lib"
  ];

  # Package set where all "final" executables are statically linked.
  #
  # In this package set, if executable E depends on package LE
  # which provides both a library and executables, then
  # E is statically linked but the executables of LE are not.
  #
  # Of course we could also make a different package set instead,
  # where executables from E and LE are all statically linked.
  # Then we would not need to make this `haskellPackages` on top
  # of what it's based on.
  # But we don't do that in order to cause as little needed rebuilding
  # of libraries vs cache.nixos.org as possible.
  haskellPackages =
    lib.mapAttrs (name: value:
      if isExecutable value then statify value else value
    ) haskellPackagesWithLibsReadyForStaticLinking;



in
  rec {
    working = {
      inherit (haskellPackages)
        hello # Minimal dependencies
        stack # Many dependencies
        hlint
        ShellCheck
        cabal-install
        bench
        dhall
        cachix
        darcs # Has native dependencies (`libcurl` and its dependencies)
        pandoc # Depends on Lua
        hsyslog # Small example of handling https://github.com/NixOS/nixpkgs/issues/43849 correctly
        ;
    };

    notWorking = {
      inherit (haskellPackages)
        xmonad
        # Uses `random_r()` glibc extension which musl doesn't have, see:
        #   https://github.com/haskell-numerics/hmatrix/issues/279
        hmatrix
        ;
    };

    all = working // notWorking;


    # Tries to build all executables on Stackage.
    allStackageExecutables =
      lib.filterAttrs (name: x: isStackageExecutable name) haskellPackages;


    inherit normalPkgs;
    inherit pkgs;
    inherit lib;

    inherit normalHaskellPackages;
    inherit haskellPackagesWithFailingStackageTestsDisabled;
    inherit haskellPackagesWithLibsReadyForStaticLinking;
    inherit haskellPackages;
  }

# TODO Update README to depend on nixpkgs master in use (instead of nh2's fork), and write something that picks nh2's patches I use on top here
# TODO Instead of picking https://github.com/NixOS/nixpkgs/pull/43713, use a Python script to dedupe `-L` flags from the NIX_*LDFLAGS variables
