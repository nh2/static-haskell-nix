let
  # TODO: Remove when https://github.com/NixOS/cabal2nix/pull/360 is merged and available
  cabal2nix-fix-overlay = final: previous:
    with final.haskell.lib; {
      haskellPackages = previous.haskellPackages.override (old: {
        overrides = final.lib.composeExtensions (old.overrides or (_: _: {})) (

          self: super: {
            cabal2nix = overrideCabal super.cabal2nix (old: {
              src = pkgs.fetchFromGitHub {
                owner = "nh2";
                repo = "cabal2nix";
                rev = "5721bed2a598a018119413bfe868bd286735cb15";
                sha256 = "1436ri6nlfcgd263byb596dcx6g4l9fx47hm11vfh34x849r2kcy";
              };
            });

          }
        );
      });
    };

  normalPkgs = import <nixpkgs> {};

  pkgs = (import <nixpkgs> {
    config.allowUnfree = true;
    config.allowBroken = true;
    # config.permittedInsecurePackages = [
    #   "webkitgtk-2.4.11"
    # ];
    overlays = [ cabal2nix-fix-overlay ];
  }).pkgsMusl;

in

{ compiler ? "ghc843" }:


let

  normalHaskellPackages = pkgs.haskellPackages;



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
            then builtins.trace "broken because of broken deps: ${pkg}" broken
            else broken
      ) libraryDepends;

  # Nixpkgs contains both Hackage and Stackage packages.
  # We want to build only executables that are on Stackage because
  # we know that those should build.
  # Find all Stackage package names here so we can use them
  # as a filter.
  # Done by parsing the configuration file that contains
  # which packages come from Stackage.
  stackagePackages =
    let
      stackageInfoPath = <nixpkgs/pkgs/development/haskell-modules/configuration-hackage2nix.yaml>;
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

  # Stackage package names we want to blacklist.
  blacklist = [
    # Test suite loops forever (see https://github.com/nh2/static-haskell-nix/issues/4#issuecomment-406612724)
    "courier"
  ];

  # All Stackage executables who (and whose dependencies) are not marked
  # as broken in nixpkgs.
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

  # Making it a set for faster lookup
  stackageExecutablesSet = keySet (builtins.attrNames stackageExecutables);
  isStackageExecutable = name: builtins.hasAttr name stackageExecutablesSet;

  numStackageExecutables = lib.length (builtins.attrNames stackageExecutables);

  # Just for debugging / statistics:
  # Same thing with "-traced" suffix to nicely print
  # which executables we're going to build.
  stackageExecutablesNames = builtins.attrNames stackageExecutables;
  stackageExecutables-traced =
    builtins.trace
      ("selected stackage executables:\n"
        + lib.concatStringsSep "\n" stackageExecutablesNames
        + "\n---\n${toString (lib.length stackageExecutablesNames)} executables total"
      )
      stackageExecutables;


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
  haskellPackagesWithLibsReadyForStaticLinking = with pkgs.haskell.lib; normalHaskellPackages.override (old: {
    overrides = pkgs.lib.composeExtensions (old.overrides or (_: _: {})) (self: super: {

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

      darcs = appendConfigureFlag (super.darcs.override { curl = curl_static; }) [
        # Ugly alert: We use `--start-group` to work around the fact that
        # the linker processes `-l` flags in the order they are given,
        # so order matters, see
        #   https://stackoverflow.com/questions/11893996/why-does-the-order-of-l-option-in-gcc-matter
        # and GHC inserts these flags too early, that is in our case, before
        # the `-lcurl` that pulls in these dependencies; see
        #   https://github.com/haskell/cabal/pull/5451#issuecomment-406759839
        "--ld-option=--start-group"

        # TODO Condition those on whether curl has them enabled.
        # But it is not clear how we can query that; curl doesn't
        # have the boolean arguments that determine it in `passthru`.
        # TODO Even better, propagate these flags from curl somehow.

        # Note: This is the order in which linking would work even if
        # `--start-group` wasn't given.
        "--ld-option=-lgssapi_krb5"
        "--ld-option=-lcom_err"
        "--ld-option=-lkrb5support"
        "--ld-option=-lkrb5"
        "--ld-option=-lkrb5support"
        "--ld-option=-lk5crypto"

        "--ld-option=-lssl"
        "--ld-option=-lcrypto"
        "--ld-option=-lnghttp2"
        "--ld-option=-lssh2"
      ];


      postgresql-libpq = super.postgresql-libpq.override { postgresql = postgresql_static; };
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
  # Then we would not need to distinguish between
  # `haskellPackages` and `haskellPackagesWithLibsReadyForStaticLinking`.
  # But we don't do that in order to cause as little needed rebuilding
  # of libraries vs cache.nixos.org as possible.
  haskellPackages =
    lib.mapAttrs (name: value:
      # For debugging: Enable this trace to see which packages will be built.
      #builtins.trace "${name} ${toString (isExecutable value)}"
      (if isExecutable value then statify value else value)
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
    inherit haskellPackagesWithLibsReadyForStaticLinking;
    inherit haskellPackages;
  }

# TODO Update README to depend on nixpkgs master in use (instead of nh2's fork), and write something that picks nh2's patches I use on top here
# TODO Instead of picking https://github.com/NixOS/nixpkgs/pull/43713, use a Python script to dedupe `-L` flags from the NIX_*LDFLAGS variables
