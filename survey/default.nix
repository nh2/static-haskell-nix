let
  cython-disable-tests-overlay = pkgs: final: previous: {
    python27 = pkgs.python27.override {
      packageOverrides = self: super: {
        cython = super.cython.overridePythonAttrs (old: rec {
          # TODO Remove once Cython tests are no longer flaky. See
          #   https://github.com/nh2/static-haskell-nix/issues/6#issuecomment-420452838
          #   https://github.com/cython/cython/issues/2602
          doCheck = false;
        });
      };
    };
  };

  # TODO cachix that
  ghc-musl-no-llvm-overlay = final: previous: {
    haskell = final.lib.recursiveUpdate previous.haskell {
      compiler.ghc864 = (previous.haskell.compiler.ghc864.override { useLLVM = false; });
    };
  };

in

{
  tracing ? false, # Enable this to see debug traces

  normalPkgs ? (import <nixpkgs> {}),

  overlays ? [],

  approach ? # "pkgsMusl" or "pkgsStatic"
    # TODO Find out why `pkgsStatic` creates ~3x larger binaries.
    "pkgsMusl", # does not exercise cross compilation
    # "pkgsStatic", # exercises cross compilation

  pkgs ? (import normalPkgs.path {
    config.allowUnfree = true;
    config.allowBroken = true;
    # config.permittedInsecurePackages = [
    #   "webkitgtk-2.4.11"
    # ];
    overlays = overlays ++ [
      (cython-disable-tests-overlay normalPkgs)
      # ghc-musl-no-llvm-overlay
    ];
  })."${approach}",

  # When changing this, also change the default version of Cabal declared below
  compiler ? "ghc864",
  # compiler ? "ghc865", # TODO cachix that with haskellPackages.hello

  defaultCabalPackageVersionComingWithGhc ? "Cabal_2_4_1_0", # TODO this is incorrect for ghc 8.6.4, should be 2.4.0.1, but nixpkgs doesn't have that

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

  trace = message: value:
    if tracing then builtins.trace message value else value;

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
      stackageInfoPath = pkgs.path + "/pkgs/development/haskell-modules/configuration-hackage2nix.yaml";
      pythonWithYaml = pkgs.python2Packages.python.withPackages (pkgs: [pkgs.pyyaml]);
      dont-distribute-packages-file = normalPkgs.runCommand "test" {} ''
        ${pythonWithYaml}/bin/python -c 'import yaml, json; x = yaml.load(open("${stackageInfoPath}")); print(json.dumps([line.split(" ")[0] for line in x["default-package-overrides"]]))' > $out
      '';
      dont-distribute-packages = builtins.fromJSON (builtins.readFile dont-distribute-packages-file);
    in
      dont-distribute-packages;

  # Turns a list into a "set" (map where all values are {}).
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

  buildPlatformHaskellPackagesWithFixedCabal = with pkgs.haskell.lib;
    let
      # For cross (`pkgsStatic`) the Setup.hs -> ./Setup compilation happens on
      # the *host* platform, not the target platform, so we need to use the
      # normal (no-musl) Cabal for that.
      # For non-cross (`pkgsMusl`) we need to use the musl-Cabal because
      # otherwise we get linking errors with missing glibc symbols.
      pkgsToUseForSetupExe =
        if approach == "pkgsStatic"
          then normalPkgs
          else pkgs;
    in
      pkgsToUseForSetupExe.haskell.packages."${compiler}".override (old: {
        overrides = pkgs.lib.composeExtensions (old.overrides or (_: _: {})) (self: super: {

          Cabal =
            # If null, super.Cabal is a non-overriden package coming with GHC.
            # In that case, we can't patch it (we can't add patches to derivations that are null).
            # So we need to instead add a not-with-GHC Cabal package and patch that.
            # The best choice for that is the version that comes with the GHC.
            # Unfortunately we can't query that easily, so we maintain that manually
            # in `defaultCabalPackageVersionComingWithGhc`.
            # That effort will go away once all our Cabal patches are upstreamed.
            if builtins.isNull super.Cabal
              then applyPatchesToCabalDrv super."${defaultCabalPackageVersionComingWithGhc}"
              else applyPatchesToCabalDrv super.Cabal;

        });
      });

  # Some settings we want to set for all packages before doing anything static-related.
  haskellPackagesWithSettings = with pkgs.haskell.lib; normalHaskellPackages.override (old: {
    overrides = pkgs.lib.composeExtensions (old.overrides or (_: _: {})) (self: super: {
      # Overriding `mkDerivation` sets these things for all Haskell packages.
      mkDerivation = attrs: super.mkDerivation (attrs // {

        # Disable haddocks to save time and because for some reason, haddock (e.g. for aeson)
        # fails with
        #     <command line>: can't load .so/.DLL for: libgmp.so (libgmp.so: cannot open shared object file: No such file or directory)
        # since we use `pkgsStatic`. Need to investigate.
        doHaddock = false;

        # Disable profiling to save time
        enableLibraryProfiling = false;
        enableExecutableProfiling = false;

      });
    });
  });

  # A `haskellPackages` set in which tests are skipped (`dontCheck`) for
  # all packages that are marked as failing their tests on Stackage
  # or known for failing their tests for other reasons.
  # Note this may disable more tests than necessary because some packages'
  # tests may work fine in nix when they don't work on Stackage,
  # for example due to more system dependencies being available.
  haskellPackagesWithFailingStackageTestsDisabled = with pkgs.haskell.lib; haskellPackagesWithSettings.override (old: {
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
            # TODO: Remove when https://github.com/ekmett/ad/pull/76 is merged and available
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
    # Doesn't build in `normalPkgs.haskellPackages` either
    "mercury-api"
    # https://github.com/nh2/static-haskell-nix/issues/6#issuecomment-420494800
    "sparkle"
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

  makeCabalPatch = { name, url, sha256 }:
    let
      # We use `runCommand` on a plain patch file instead of using
      # `fetchpatch`'s `includes` or `stripLen` features to not run
      # into the perils of:
      #   https://github.com/NixOS/nixpkgs/issues/48567
      plainPatchFile = pkgs.fetchpatch { inherit name url sha256; };

      # Explanation:
      #   * A patch created for the cabal project's source tree will
      #     always have subdirs `Cabal` and `cabal-install`; the
      #     `Cabal` nix derivation is already the `Cabal` subtree.
      #   * We run `filterdiff -i` to keep only changes from the patch
      #     that apply to the `Cabal` subtree.
      #   * We run `filterdiff -x` to remove Changelog files which
      #     almost always conflict.
      #   * `-p1` strips away the `a/` and `b/` before `-i`/`-x` apply.
      #   * `strip=2` removes e.g `a/Cabal` so that the patch applies
      #     directly to that source tree, `--add*prefix` adds back the
      #     `a/` and `b/` that `patch -p1` expects.
      patchOnCabalLibraryFilesOnly = pkgs.runCommand "${name}-Cabal-only" {} ''
        ${pkgs.patchutils}/bin/filterdiff \
          -p1 -i 'Cabal/*' -x 'Cabal/ChangeLog.md' \
          --strip=2 --addoldprefix=a/ --addnewprefix=b/ \
          ${plainPatchFile} > $out

        if [ ! -s "$out" ]; then
          echo "error: Filtered patch '$out' is empty (while the original patch file was not)!" 1>&2
          echo "Check your includes and excludes." 1>&2
          echo "Normalizd patch file was:" 1>&2
          cat "${plainPatchFile}" 1>&2
          exit 1
        fi
      '';

    in
      patchOnCabalLibraryFilesOnly;

  applyPatchesToCabalDrv = cabalDrv: pkgs.haskell.lib.overrideCabal cabalDrv (old: {
    patches =
      # Patches we know are merged in a certain cabal version
      # (we include them conditionally here anyway, for the case
      # that the user specifies a different Cabal version e.g. via
      # `stack2nix`):
      (builtins.concatLists [
        # -L flag deduplication
        #   https://github.com/haskell/cabal/pull/5356
        (lib.optional (pkgs.lib.versionOlder cabalDrv.version "2.4.0.0") (makeCabalPatch {
          name = "5356.patch";
          url = "https://github.com/haskell/cabal/commit/fd6ff29e268063f8a5135b06aed35856b87dd991.patch";
          sha256 = "1l5zwrbdrra789c2sppvdrw3b8jq241fgavb8lnvlaqq7sagzd1r";
        }))
      # Patches that as of writing aren't merged yet:
      ]) ++ [
        # TODO Move this into the above section when merged in some Cabal version:
        # --enable-executable-static
        #   https://github.com/haskell/cabal/pull/5446
        (if pkgs.lib.versionOlder cabalDrv.version "2.4.0.0"
          then
            # Older cabal, from https://github.com/nh2/cabal/commits/dedupe-more-include-and-linker-flags-enable-static-executables-flag-pass-ld-options-to-ghc-Cabal-v2.2.0.1
            (makeCabalPatch {
              name = "5446.patch";
              url = "https://github.com/haskell/cabal/commit/748f07b50724f2618798d200894f387020afc300.patch";
              sha256 = "1zmbalkdbd1xyf0kw5js74bpifhzhm16c98kn7kkgrwql1pbdyp5";
            })
          else
            (makeCabalPatch {
              name = "5446.patch";
              url = "https://github.com/haskell/cabal/commit/cb221c23c274f79dcab65aef3756377af113ae21.patch";
              sha256 = "02qalj5y35lq22f19sz3c18syym53d6bdqzbnx9f6z3m7xg591p1";
            })
        )
        # TODO Move this into the above section when merged in some Cabal version:
        # ld-option passthrough
        #   https://github.com/haskell/cabal/pull/5451
        (if pkgs.lib.versionOlder cabalDrv.version "2.4.0.0"
          then
            # Older cabal, from https://github.com/nh2/cabal/commits/dedupe-more-include-and-linker-flags-enable-static-executables-flag-pass-ld-options-to-ghc-Cabal-v2.2.0.1
            (makeCabalPatch {
              name = "5451.patch";
              url = "https://github.com/haskell/cabal/commit/b66be72db3b34ea63144b45fcaf61822e0fade87.patch";
              sha256 = "0hndkfb96ry925xzx85km8y8pfv5ka5jz3jvy3m4l23jsrsd06c9";
            })
          else
            (makeCabalPatch {
              name = "5451.patch";
              url = "https://github.com/haskell/cabal/commit/0aeb541393c0fce6099ea7b0366c956e18937791.patch";
              sha256 = "0pa9r79730n1kah8x54jrd6zraahri21jahasn7k4ng30rnnidgz";
            })
        )
      ];
  });

  useFixedCabal =
    let
      patchIfCabal = drv:
        if (drv.pname or "") == "Cabal" # the `ghc` package has not `pname` attribute, so we default to "" here
          then applyPatchesToCabalDrv drv
          else drv;
      patchCabalInPackageList = drvs:
        let
          # Packages that come with the GHC version used have
          # `null` as their derivation (e.g. `text` or `Cabal`
          # if they are not overridden). We filter them out here.
          nonNullPackageList = builtins.filter (drv: !(builtins.isNull drv)) drvs;
        in
          map patchIfCabal nonNullPackageList;
      fixedCabal = buildPlatformHaskellPackagesWithFixedCabal.Cabal;
    in
      drv: (pkgs.haskell.lib.overrideCabal drv (old: {
        # If the package already depends on some explicit version
        # of Cabal, patch it, so that it has --enable-executable-static.
        # If it doesn't (it depends on the version of Cabal that comes
        # with GHC instead), add the same version that comes with
        # that GHC, but with our patches.
        # Unfortunately we don't have the final package set at hand
        # here, so we use the `haskellPackagesWithLibsReadyForStaticLinking`
        # one instead which has set `Cabal = ...` appropriately.
        setupHaskellDepends = patchCabalInPackageList ((old.setupHaskellDepends or []) ++ [fixedCabal]);
        # We also need to add the fixed cabal to the normal dependencies,
        # for the case that the package itself depends on Cabal; see note
        # [Fixed Cabal for Setup.hs->somePackage->Cabal dependencies].
        libraryHaskellDepends = patchCabalInPackageList ((old.libraryHaskellDepends or []) ++ [fixedCabal]);
      })).overrideAttrs (old: {
        # Adding the fixed Cabal version to `setupHaskellDepends` is not enough:
        # There may already be one in there, in which case GHC picks an
        # arbitrary one.
        # So we determine the package key of the Cabal we want, and pass it
        # directly to GHC.
        preCompileBuildDriver = ''
          cabalPackageId=$(basename --suffix=.conf ${fixedCabal}/lib/ghc-*/package.conf.d/*.conf)
          echo "Determined cabalPackageId as $cabalPackageId"

          setupCompileFlags="$setupCompileFlags -package-id $cabalPackageId"
        '';
      });


  # Overriding system libraries that don't provide static libs
  # (`.a` files) by default

  # TODO Make all these overrides an overlay.
  #      Then we don't have to pass overridden libs explicitly
  #      to other libs, or to Haksell packages.

  libffi_static = pkgs.libffi.overrideAttrs (old: { dontDisableStatic = true; });

  sqlite_static = pkgs.sqlite.overrideAttrs (old: { dontDisableStatic = true; });

  lzma_static = pkgs.lzma.overrideAttrs (old: { dontDisableStatic = true; });

  zlib_static = if approach == "pkgsStatic" then pkgs.zlib else pkgs.zlib.static;

  postgresql_static = (pkgs.postgresql.overrideAttrs (old: { dontDisableStatic = true; })).override {
    # We need libpq, which does not need systemd,
    # and systemd doesn't currently build with musl.
    enableSystemd = false;
    openssl = openssl_static;
    zlib = zlib_static;
  };

  pcre_static = pkgs.pcre.overrideAttrs (old: { dontDisableStatic = true; });

  expat_static = pkgs.expat.overrideAttrs (old: { dontDisableStatic = true; });

  mpfr_static = pkgs.mpfr.overrideAttrs (old: { dontDisableStatic = true; });

  gmp_static = pkgs.gmp.overrideAttrs (old: { dontDisableStatic = true; });

  libxml2_static = pkgs.libxml2.overrideAttrs (old: { dontDisableStatic = true; });

  nettle_static = pkgs.nettle.overrideAttrs (old: { dontDisableStatic = true; });

  bzip2_static = pkgs.bzip2.overrideAttrs (old: { dontDisableStatic = true; });

  nghttp2_static = pkgs.nghttp2.overrideAttrs (old: { dontDisableStatic = true; });

  libssh2_static = (pkgs.libssh2.overrideAttrs (old: { dontDisableStatic = true; })).override {
    openssl = openssl_static;
    zlib = zlib_static;
  };

  keyutils_static = pkgs.keyutils.overrideAttrs (old: { dontDisableStatic = true; });

  libxcb_static = pkgs.xorg.libxcb.overrideAttrs (old: { dontDisableStatic = true; });
  # We'd like to make this depend on libxcb_static somehow, but neither adding
  # it to `buildInputs` via `overrideAttrs`, nor setting it with `.override`
  # seems to have the desired effect for the eventual link of `xmonad`.
  # So we use a custom `--ghc-options` hack for `xmonad` below.
  libX11_static = pkgs.xorg.libX11.overrideAttrs (old: { dontDisableStatic = true; });
  libXext_static = pkgs.xorg.libXext.overrideAttrs (old: { dontDisableStatic = true; });
  libXinerama_static = pkgs.xorg.libXinerama.overrideAttrs (old: { dontDisableStatic = true; });
  libXrandr_static = pkgs.xorg.libXrandr.overrideAttrs (old: { dontDisableStatic = true; });
  libXrender_static = pkgs.xorg.libXrender.overrideAttrs (old: { dontDisableStatic = true; });
  libXScrnSaver_static = pkgs.xorg.libXScrnSaver.overrideAttrs (old: { dontDisableStatic = true; });
  libXau_static = pkgs.xorg.libXau.overrideAttrs (old: { dontDisableStatic = true; });
  libXdmcp_static = pkgs.xorg.libXdmcp.overrideAttrs (old: { dontDisableStatic = true; });

  # TODO: Once these are an overlay, override only `openblas` and not
  #       `openblasCompat`, because the latter is an override of the former.
  openblas_static = pkgs.openblas.override { enableStatic = true; };
  openblasCompat_static = pkgs.openblasCompat.override { enableStatic = true; };

  krb5_static = pkgs.krb5.override {
    # Note krb5 does not support building both static and shared at the same time.
    staticOnly = true;
    keyutils = keyutils_static;
  };

  openssl_static = pkgs.openssl.override { static = true; };

  curl_static = (pkgs.curl.override {
    nghttp2 = nghttp2_static;
    zlib = zlib_static;
    libssh2 = libssh2_static;
    libkrb5 = krb5_static;
    openssl = openssl_static;
  }).overrideAttrs (old: {
    dontDisableStatic = true;
    # Using configureFlagsArray because when passing multiple `LIBS`, we have to have spaces inside that variable.
    configureFlagsArray = [
      # When linking krb5 statically, one has to pass -lkrb5support explicitly
      # because core functions such as `k5_clear_error` are in
      # `libkrb5support.a` and not in `libkrb5.a`.
      # See https://stackoverflow.com/questions/39960588/gcc-linking-with-kerberos-for-compiling-with-curl-statically/41822755#41822755
      #
      # Also pass -lkeyutils explicitly because krb5 depends on it; otherwise users of libcurl get linker errors like
      #   ../lib/.libs/libcurl.so: undefined reference to `add_key'
      #   ../lib/.libs/libcurl.so: undefined reference to `keyctl_get_keyring_ID'
      #   ../lib/.libs/libcurl.so: undefined reference to `keyctl_unlink'
      "LIBS=-lkrb5support -L${keyutils_static.lib}/lib -lkeyutils"
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
          "--ld-option=-Wl,--start-group"
        ]) (old: {
          # We can't pass all linker flags in one go as `ld-options` because
          # the generic Haskell builder doesn't let us pass flags containing spaces.
          preConfigure = builtins.concatStringsSep "\n" [
            (old.preConfigure or "")
            ''
              set -e
              configureFlags+=$(for flag in $(pkg-config --static ${pkgconfigFlagsString}); do echo -n " --ld-option=$flag"; done)
            ''
          ];
          # TODO Somehow change nixpkgs (the generic haskell builder?) so that
          # putting `curl_static` into `libraryPkgconfigDepends` is enough
          # and the manual modification of `configureFlags` is not necessary.
          libraryPkgconfigDepends = (old.libraryPkgconfigDepends or []) ++ pkgConfigNixPackages;
        });

        callCabal2nix =
          # TODO: Need to check which of these is better.
          #       They pull in `nix` and some ghc, so where these comes from matters.
          # normalHaskellPackages.callCabal2nix;
          normalPkgs.haskellPackages.callCabal2nix;

    in {

      # Note [Fixed Cabal for Setup.hs->somePackage->Cabal dependencies]
      # We have to add our fixed Cabal to the package set because otherwise
      # packages that depend on Cabal (e.g. `cabal-doctest`) will depend
      # on the unfixed Cabal, and when some other Setup.hs depends
      # on such a package, GHC will choose the unfixed Cabal to use.
      # `pkgsStatic` does not need this because with it, because when
      # cross-compiling, the Setup.hs is compiled with a completely different
      # package set.
      # Example packages:
      #   Some getting: unrecognized 'configure' option `--enable-executable-static'
      #     influxdb
      #     wreq
      #     servant-server
      #   Some getting: *** abort because of serious configure-time warning from Cabal (multiple different package versions in project)
      #     stack2nix
      Cabal =
        if approach == "pkgsMusl"
          then buildPlatformHaskellPackagesWithFixedCabal.Cabal
          else super.Cabal; # `pkgsStatic` does not need that

      # Helpers for other packages

      hpc-coveralls = appendPatch super.hpc-coveralls (builtins.fetchurl https://github.com/guillaume-nargeot/hpc-coveralls/pull/73/commits/344217f513b7adfb9037f73026f5d928be98d07f.patch);
      persistent-sqlite = super.persistent-sqlite.override { sqlite = sqlite_static; };
      lzma = super.lzma.override { lzma = lzma_static; };

      hpack = super.hpack;
      hackage-security = super.hackage-security;

      # TODO: Remove this once we are on conduit-extra >= 1.3.1.1, and check if it reappears
      # Test-suite failing nondeterministically, see https://github.com/snoyberg/conduit/issues/385
      conduit-extra = dontCheck super.conduit-extra;

      # cachix = overrideCabal super.cachix (old: {
      #   # A Hackage cabal revision turned \n into \r\n for cachix.cabal.
      #   # So our patch doesn't apply without previous use of `dos2unix`.
      #   # See https://mail.haskell.org/pipermail/haskell-cafe/2019-May/131097.html
      #   prePatch = ''
      #     ${pkgs.dos2unix}/bin/dos2unix cachix.cabal
      #   '';
      #   patches = (old.patches or []) ++ [
      #     /home/niklas/src/haskell/cachix/cachix/0001-cabal-Don-t-list-Paths_cachix-in-other-modules.patch
      #   ];
      # });

      # See https://github.com/hslua/hslua/issues/67
      # It's not clear if it's safe to disable this as key functionality may be broken
      hslua = dontCheck super.hslua;

      regex-pcre = super.regex-pcre.override { pcre = pcre_static; };
      pcre-light = super.pcre-light.override { pcre = pcre_static; };

      HsOpenSSL = super.HsOpenSSL.override { openssl = openssl_static; };
      hopenssl = super.hopenssl.override { openssl = openssl_static; };

      bzlib-conduit = super.bzlib-conduit.override { bzip2 = bzip2_static; };

      darcs =
        addStaticLinkerFlagsWithPkgconfig
          (super.darcs.override { curl = curl_static; })
          [ curl_static ]
          # Ideally we'd like to use
          #   pkg-config --static --libs libcurl
          # but that doesn't work because that output contains `-Wl,...` flags
          # which aren't accepted by `ld` and thus cannot be passed as `ld-option`s.
          # See https://github.com/curl/curl/issues/2775 for an investigation of why.
          "--libs-only-L --libs-only-l libcurl";

      # For https://github.com/BurntSushi/erd/issues/40
      # As of writing, not in Stackage
      erd = doJailbreak super.erd;

      hmatrix = ((drv: enableCabalFlag drv "no-random_r") (overrideCabal super.hmatrix (old: {
        # The patch does not apply cleanly because the cabal file
        # was Hackage-revisioned, which converted it to Windows line endings
        # (https://github.com/haskell-numerics/hmatrix/issues/302);
        # convert it back.
        prePatch = (old.prePatch or "") + ''
          ${pkgs.dos2unix}/bin/dos2unix ${old.pname}.cabal
        '';
        patches = (old.patches or []) ++ [
          (pkgs.fetchpatch {
            url = "https://github.com/nh2/hmatrix/commit/e9da224bce287653f96235bd6ae02da6f8f8b219.patch";
            name = "hmatrix-Allow-disabling-random_r-usage-manually.patch";
            sha256 = "1fpv0y5nnsqcn3qi767al694y01km8lxiasgwgggzc7816xix0i2";
            stripLen = 2;
          })
        ];
      }))).override { openblasCompat = openblasCompat_static; };

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

      xml-to-json =
        addStaticLinkerFlagsWithPkgconfig
          super.xml-to-json
          [ curl_static expat_static ]
          # Ideally we'd like to use
          #   pkg-config --static --libs libcurl
          # but that doesn't work because that output contains `-Wl,...` flags
          # which aren't accepted by `ld` and thus cannot be passed as `ld-option`s.
          # See https://github.com/curl/curl/issues/2775 for an investigation of why.
          "--libs-only-L --libs-only-l libcurl expat";

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

      # Added for #14
      tttool = callCabal2nix "tttool" (pkgs.fetchFromGitHub {
        owner = "entropia";
        repo = "tip-toi-reveng";
        rev = "f83977f1bc117f8738055b978e3cfe566b433483";
        sha256 = "05bbn63sn18s6c7gpcmzbv4hyfhn1i9bd2bw76bv6abr58lnrwk3";
      }) {};

      # TODO Remove when https://github.com/NixOS/cabal2nix/issues/372 is fixed and available
      yaml = disableCabalFlag super.yaml "system-libyaml";

      X11 = super.X11.override {
        libX11 = libX11_static;
        libXext = libXext_static;
        libXinerama = libXinerama_static;
        libXrandr = libXrandr_static;
        libXrender = libXrender_static;
        libXScrnSaver = libXScrnSaver_static;
      };

      # Note that xmonad links, but it doesn't run, because it tries to open
      # `libgmp.so.3` at run time.
      xmonad =
        let
          # Work around xmonad in `haskell-packages.nix` having hardcoded `$doc`
          # which is the empty string when haddock is disabled.
          # Same as https://github.com/NixOS/nixpkgs/pull/61526 but for
          # https://github.com/NixOS/cabal2nix/blob/fe32a4cdb909cc0a25d37ec371453b1bb0d4f134/src/Distribution/Nixpkgs/Haskell/FromCabal/PostProcess.hs#L294-L295
          # TODO: Remove when https://github.com/NixOS/cabal2nix/pull/416 is merged and available in nixpkgs.
          fixPostInstallWithHaddockDisabled = pkg: overrideCabal pkg (old: { postInstall = ""; });
        in
        appendConfigureFlag (addStaticLinkerFlagsWithPkgconfig
          (fixPostInstallWithHaddockDisabled super.xmonad)
          [ libxcb_static libXau_static libXdmcp_static ]
          "--libs xcb Xau Xdmcp") [
          # The above `--libs` `pkgconfig` override seems to have no effect
          # but it at least makes the libraries available for manual `-l` flags.
          # It's also not clear why we incur a dependency on `Xdmcp` at all.
          "--ghc-option=-lxcb --ghc-option=-lXau --ghc-option=-lXrender --ghc-option=-lXdmcp"
        ];

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

  # We have to use `useFixedCabal` here, and cannot just rely on the
  # "Cabal = ..." we override up in `haskellPackagesWithLibsReadyForStaticLinking`,
  # because that `Cabal` isn't used in all packages:
  # If a package doesn't explicitly depend on the `Cabal` package, then
  # for compiling its `Setup.hs` the Cabal package that comes with GHC
  # (that is in the default GHC package DB) is used instead, which
  # obviously doesn' thave our patches.
  statify = drv: with pkgs.haskell.lib; pkgs.lib.foldl appendConfigureFlag (disableLibraryProfiling (disableSharedExecutables (useFixedCabal drv))) ([
    # "--ghc-option=-fPIC"
    "--enable-executable-static" # requires `useFixedCabal`
    "--extra-lib-dirs=${pkgs.gmp6.override { withStatic = true; }}/lib"
    # TODO These probably shouldn't be here but only for packages that actually need them
    "--extra-lib-dirs=${zlib_static}/lib"
    "--extra-lib-dirs=${pkgs.ncurses.override { enableStatic = true; }}/lib"
  ] ++ pkgs.lib.optional (approach == "pkgsMusl") [
    # GHC needs this if it itself wasn't already built against static libffi
    # (which is the case in `pkgsStatic` only):
    "--extra-lib-dirs=${libffi_static}/lib"
  ]);

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
        hsyslog # Small example of handling https://github.com/NixOS/nixpkgs/issues/43849 correctly
        ;
    } // (if approach == "pkgsStatic" then {} else {
      # Packages that work with `pkgsMusl` but fail with `pkgsStatic`:

      inherit (haskellPackages)
        # cachix fails on `pkgsStatic` with
        #     cycle detected in the references of '/nix/store/...-cachix-0.2.0-x86_64-unknown-linux-musl-bin' from '/nix/store/...-cachix-0.2.0-x86_64-unknown-linux-musl'
        # because somehow the `Paths_cachix` module gets linked into the library,
        # and it contains a reference to the `binDir`, which is a separate nix output.
        #
        # There's probably a lack of dead-code elimination with `pkgsStatic`,
        # but even if that worked, this is odd because this should work even
        # when you *use* the `binDir` thing in your executable.
        cachix
        # darcs fails on `pkgsStatic` because
        darcs # Has native dependencies (`libcurl` and its dependencies)
        # pandoc fails on `pkgsStatic` because Lua doesn't currently build there.
        pandoc # Depends on Lua
        # xmonad fails on `pkgsStatic` because `libXScrnSaver` fails to build there.
        xmonad
        ;
    });

    notWorking = {
      inherit (haskellPackages)
        aura # Requested by the author # TODO reenable after fixing Package `language-bash-0.8.0` being marked as broken and failing to evaluate
        tttool # see #14 # TODO reenable after fixing Package `HPDF-1.4.10` being marked as broken and failing to evaluate
        ;
    };

    all = working // notWorking;


    # Tries to build all executables on Stackage.
    allStackageExecutables =
      lib.filterAttrs (name: x: isStackageExecutable name) haskellPackages;

    workingStackageExecutables =
      builtins.removeAttrs allStackageExecutables [
        # List of executables that don't work for reasons not yet investigated.
        # When changing this file, we should always check if this list grows or shrinks.
        "Agda"
        "Allure"
        "ALUT"
        "clash-ghc"
        "credential-store"
        "csg"
        "cuda" # transitively depends on `systemd`, which doesn't build with musl
        "debug"
        "diagrams-builder"
        "dotenv"
        "ersatz"
        "filter-logger"
        "focuslist" # linker error: HSghc-prim-0.5.3.o: unknown symbol `exp'
        "gloss-examples" # needs opengl
        "gtk3"
        "hamilton"
        "haskell-gi"
        "hquantlib"
        "ihaskell"
        "ipython-kernel"
        "jack"
        "LambdaHack"
        "language-puppet"
        "learn-physics"
        "lens-regex"
        "leveldb-haskell"
        "microformats2-parser"
        "mmark-cli"
        "odbc"
        "OpenAL"
        "qchas" # openmp linker error via openblas
        "rasterific-svg"
        "sdl2"
        "sdl2-gfx"
        "sdl2-image"
        "sdl2-mixer"
        "sdl2-ttf"
        "soxlib"
        "yesod-paginator"
        "yoga"
        "zeromq4-patterns"
      ];

    inherit normalPkgs;
    inherit pkgs;
    inherit lib;

    inherit normalHaskellPackages;
    inherit haskellPackagesWithFailingStackageTestsDisabled;
    inherit haskellPackagesWithLibsReadyForStaticLinking;
    inherit haskellPackages;

    inherit gmp_static;
  }
