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

in

{
  tracing ? false, # Enable this to see debug traces

  normalPkgs ? (import <nixpkgs> {}),

  overlays ? [],

  pkgs ? (import normalPkgs.path {
    config.allowUnfree = true;
    config.allowBroken = true;
    # config.permittedInsecurePackages = [
    #   "webkitgtk-2.4.11"
    # ];
    overlays = overlays ++ [ (cython-disable-tests-overlay normalPkgs) ];
  }).pkgsMusl,

  # When changing this, also change the default version of Cabal declared below
  compiler ? "ghc843",

  defaultCabalPackageVersionComingWithGhc ? "Cabal_2_2_0_1",

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
    in
      drv: pkgs.haskell.lib.overrideCabal drv (old: {
        # If the package already depends on some explicit version
        # of Cabal, patch it, so that it has --enable-executable-static.
        # If it doesn't (it depends on the version of Cabal that comes
        # with GHC instead), add the same version that comes with
        # that GHC, but with our patches.
        # Unfortunately we don't have the final package set at hand
        # here, so we use the `haskellPackagesWithLibsReadyForStaticLinking`
        # one instead which has set `Cabal = ...` appropriately.
        setupHaskellDepends = patchCabalInPackageList (old.setupHaskellDepends or [haskellPackagesWithLibsReadyForStaticLinking.Cabal]);
        # TODO Check if this is necessary
        libraryHaskellDepends = patchCabalInPackageList (old.libraryHaskellDepends or [haskellPackagesWithLibsReadyForStaticLinking.Cabal]);
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

  keyutils_static = pkgs.keyutils.overrideAttrs (old: { dontDisableStatic = true; });

  krb5_static = pkgs.krb5.override {
    # Note krb5 does not support building both static and shared at the same time.
    staticOnly = true;
    keyutils = keyutils_static;
  };

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
          "--ld-option=--start-group"
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
    in {

      Cabal =
        # If null, super.Cabal is a non-overriden package coming with GHC.
        # In that case, we can't patch it (we can't add patches to derivations that are null).
        # So we need to instead add a not-with-GHC Cabal package and patch that.
        # The best choice for that is the version that comes with the GHC.
        # Unfortunately we can't query that easily, so we maintain that manually
        # in `defaultCabalPackageVersionComingWithGhc`.
        # That effort will go away once all our Cabal patches are upstreamed.
        if builtins.isNull super.Cabal
          then applyPatchesToCabalDrv pkgs.haskell.packages."${compiler}"."${defaultCabalPackageVersionComingWithGhc}"
          else applyPatchesToCabalDrv super.Cabal;

      # Helpers for other packages

      hpc-coveralls = appendPatch super.hpc-coveralls (builtins.fetchurl https://github.com/guillaume-nargeot/hpc-coveralls/pull/73/commits/344217f513b7adfb9037f73026f5d928be98d07f.patch);
      persistent-sqlite = super.persistent-sqlite.override { sqlite = sqlite_static; };
      lzma = super.lzma.override { lzma = lzma_static; };

      hpack = super.hpack;
      hackage-security = super.hackage-security;

      # TODO: Remove this once we are on conduit-extra >= 1.3.1.1, and check if it reappears
      # Test-suite failing nondeterministically, see https://github.com/snoyberg/conduit/issues/385
      conduit-extra = dontCheck super.conduit-extra;

      # See https://github.com/hslua/hslua/issues/67
      # It's not clear if it's safe to disable this as key functionality may be broken
      hslua = dontCheck super.hslua;

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

      # aura dependencies
      throttled = self.callCabal2nix "throttled" (pkgs.fetchgit {
        # TODO Use fetchFromGitLab once we're on top of nixpkgs release-18.09
        url = "https://gitlab.com/fosskers/throttled.git";
        rev = "753edca18f9d25450bc29cb14cf4481bafad9c52";
        sha256 = "17dkmdl20hq1f08birsx9lbbg4f6v6hipvpnr9p5cd90imymd96f";
      }) {};
      language-bash = self.callCabal2nix "language-bash" (pkgs.fetchFromGitHub {
        owner = "knrafto";
        repo = "language-bash";
        rev = "726bc1295d951310696830c13cba712677765833";
        sha256 = "1ag1h3fgrxnpq5k0ik69s9m846kj0cx2wjzzhpsi5d0n38jnyqsh";
      }) {};
      non-empty-containers = self.callCabal2nix "non-empty-containers" (pkgs.fetchFromGitHub {
        owner = "andrewthad";
        repo = "non-empty-containers";
        rev = "694dae9ca49e3cb2dcd33534cdba2529bff50c6e";
        sha256 = "0qzavfr0yri8wrd0mmb3yyyk8z3xcjyqp8ijaqxkaxd5irlclrhc";
      }) {};
      algebraic-graphs = doJailbreak super.algebraic-graphs;
      generic-lens = dontCheck super.generic-lens;
      # Disable tests due to https://github.com/aurapm/aura/issues/526
      aur = dontCheck (self.callCabal2nix "aur" ((pkgs.fetchFromGitHub {
        owner = "aurapm";
        repo = "aura";
        rev = "9652a3bff8c6a6586513282306b3ce6667318b00";
        sha256 = "1mwshmvvnnw77pfr6xhjqmqmd0wkmgs84zzxmqzdycz8jipyjlmf";
      }) + "/aur") {});

      aura =
        let
          aura_src = pkgs.fetchFromGitHub {
            owner = "aurapm";
            repo = "aura";
            rev = "9652a3bff8c6a6586513282306b3ce6667318b00";
            sha256 = "1mwshmvvnnw77pfr6xhjqmqmd0wkmgs84zzxmqzdycz8jipyjlmf";
          };

          aura_aura_subdir = pkgs.stdenv.mkDerivation {
            name = "aura-src";
            buildCommand = ''
              cp -rv ${aura_src}/aura/ $out
              cd $out
              chmod 700 $out
              touch aura.cabal
              chmod 700 aura.cabal
              ${self.hpack}/bin/hpack --force
              rm package.yaml
            '';
          };
        in
          doJailbreak (self.callCabal2nix "aur" aura_aura_subdir {});

      # Added for #14
      tttool = self.callCabal2nix "tttool" (pkgs.fetchFromGitHub {
        owner = "entropia";
        repo = "tip-toi-reveng";
        rev = "f83977f1bc117f8738055b978e3cfe566b433483";
        sha256 = "05bbn63sn18s6c7gpcmzbv4hyfhn1i9bd2bw76bv6abr58lnrwk3";
      }) {};

      # TODO Remove when https://github.com/NixOS/cabal2nix/issues/372 is fixed and available
      yaml = disableCabalFlag super.yaml "system-libyaml";

      stack = overrideCabal super.stack (old: {
        # The enabled-by-default flag 'disable-git-info' needs the `git` tool in PATH.
        executableToolDepends = [ pkgs.git ];
      });

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
        aura # Requested by the author
        tttool # see #14
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
        "debug"
        "diagrams-builder"
        "dotenv"
        "ersatz"
        "filter-logger"
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
  }
