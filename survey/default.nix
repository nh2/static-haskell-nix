let
  cython-disable-tests-overlay = final: previous: {
    python27 = previous.python27.override {
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

  approach ? # "pkgsMusl" or "pkgsStatic"
    # TODO Find out why `pkgsStatic` creates ~3x larger binaries.
    "pkgsMusl", # does not exercise cross compilation
    # "pkgsStatic", # exercises cross compilation

  # Note that we must NOT use something like `import normalPkgs.path {}`.
  # It is bad because it removes previous overlays.
  pkgs ? (normalPkgs.appendOverlays [
    cython-disable-tests-overlay
  ])."${approach}",

  # When changing this, also change the default version of Cabal declared below
  compiler ? "ghc864",

  defaultCabalPackageVersionComingWithGhc ?
    ({
      ghc822 = "Cabal_2_2_0_1"; # TODO this is technically incorrect for ghc 8.2.2, should be 2.0.1.0, but nixpkgs doesn't have that
      ghc844 = "Cabal_2_2_0_1";
      ghc863 = throw "static-haskell-nix: ghc863 is no longer supported, please upgrade";
      ghc864 = "Cabal_2_4_1_0"; # TODO this is technically incorrect for ghc 8.6.4, should be 2.4.0.1, but nixpkgs doesn't have that
      ghc865 = "Cabal_2_4_1_0"; # TODO this is technically incorrect for ghc 8.6.5, should be 2.4.0.1, but nixpkgs doesn't have that
    }."${compiler}"),

  # Use `integer-simple` instead of `integer-gmp` to avoid linking in
  # this LGPL dependency statically.
  integer-simple ? false,

  # Enable for fast iteration.
  # Note that this doesn't always work. I've already found tons of bugs
  # in packages when `-O0` is used, like
  #   * https://github.com/bos/double-conversion/issues/26
  #   * https://github.com/bos/blaze-textual/issues/11
  # and also a few ultra-weird errors like `hpack` failing to link with
  # errors like this when building `hpack` from a `stack2nix` project
  # built statically:
  #     /nix/store/...-binutils-2.31.1/bin/ld: /nix/store/...-Cabal-2.4.1.0/lib/ghc-8.6.4/x86_64-linux-ghc-8.6.4/Cabal-2.4.1.0-.../libHSCabal-2.4.1.0-CZ6S6W3ko5J53WiB3G8d5G.a(Class.o):(.text.s2t5E_info+0x45): undefined reference to `parseczm3zi1zi13zi0zm2FiyouGhSt6Ln2s2okK4LQ_TextziParsecziPrim_zlz3fUzg2_info'
  # after which resuming the build with `./Setup build --ghc-option=-O`
  # (with `-O`!) I saw the likely cause:
  #     /nix/store/waszsfh43jli6p8d0my8cb5ahrcksxif-Cabal-2.4.1.0/lib/ghc-8.6.4/x86_64-linux-ghc-8.6.4/Cabal-2.4.1.0-CZ6S6W3ko5J53WiB3G8d5G/Distribution/Parsec/Class.hi
  #     Declaration for explicitEitherParsec
  #     Unfolding of explicitEitherParsec:
  #       Can't find interface-file declaration for variable $fApplicativeParsecT1
  #         Probable cause: bug in .hi-boot file, or inconsistent .hi file
  #         Use -ddump-if-trace to get an idea of which file caused the error
  # so use this carefully.
  # I hope that garbage like the last error will go away once we finally
  # no longer have to patch Cabal and inject it into packages.
  disableOptimization ? false,
}:

let

  trace = message: value:
    if tracing then builtins.trace message value else value;

  lib = pkgs.lib;

  # Function that tells  us if a given entry in a `haskellPackages` package set
  # is a proper Haskell package (as opposed to some fancy function like
  # `.override` and the likes).
  isProperHaskellPackage = val:
    lib.isDerivation val && # must pass lib.isDerivation
    val ? env; # must have an .env key

  # Function that tells us if a given Haskell package has an executable.
  # Pass only Haskell packages to this!
  # Filter away other stuff with `isProperHaskellPackage` first.
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
          res = builtins.tryEval (isProperHaskellPackage x && isBroken x);
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
      haskellPackagesToUseForSetupExe =
        if integer-simple
          then pkgsToUseForSetupExe.haskell.packages.integer-simple."${compiler}"
          else pkgsToUseForSetupExe.haskell.packages."${compiler}";
    in
      haskellPackagesToUseForSetupExe.override (old: {
        overrides = pkgs.lib.composeExtensions (old.overrides or (_: _: {})) (self: super: {

          Cabal =
            # Note [When Cabal is `null` in a package set]
            #
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

  # TODO `haskellPackagesWithFailingStackageTestsDisabled` is currently unused
  #      now that we've switched to overlays, we may want to use it again in the future.

  # A `haskellPackages` set in which tests are skipped (`dontCheck`) for
  # all packages that are marked as failing their tests on Stackage
  # or known for failing their tests for other reasons.
  # Note this may disable more tests than necessary because some packages'
  # tests may work fine in nix when they don't work on Stackage,
  # for example due to more system dependencies being available.
  haskellPackagesWithFailingStackageTestsDisabled = with pkgs.haskell.lib; haskellPackages.override (old: {
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
      normalHaskellPackages =
        if integer-simple
          then pkgs.haskell.packages.integer-simple."${compiler}"
          else pkgs.haskell.packages."${compiler}";

      stackageExecutables = lib.filterAttrs (name: x: isStackagePackage name && !(lib.elem name blacklist) && (
        let
          res = builtins.tryEval (
               isProperHaskellPackage x
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
        # We don't need to add it to `libraryHaskellDepends` (see note
        # [Fixed Cabal for Setup.hs->somePackage->Cabal dependencies])
        # here because we already add it to the package set itself
        # down in `haskellLibsReadyForStaticLinkingOverlay`.
        # In fact, adding it here breaks e.g. the example in
        # `static-stack`, because `stack2nix` adds stacks specified
        # `Cabal` dependency as `libraryHaskellDepends`
        # (which is then patched via `applyPatchesToCabalDrv` in
        # `haskellLibsReadyForStaticLinkingOverlay`) and adding
        # it here would add a second, different Cabal version to the
        # ghc package DB.
      })).overrideAttrs (old: {
        # Adding the fixed Cabal version to `setupHaskellDepends` is not enough:
        # There may already be one in there, in which case GHC picks an
        # arbitrary one.
        # So we determine the package key of the Cabal we want, and pass it
        # directly to GHC.
        # Tip: If you want to debug this when it's failing, see
        #      https://github.com/NixOS/nixpkgs/issues/65210#issuecomment-513515829
        # A common reason for it to fail is when the wrong `compiler` is given;
        # in that case, the build log of the `Cabal` package involved will show
        # two different ghc versions, and the output's `lib` directory will also
        # contain 2 different ghc versions (one with the `.o` files and one with
        # the `.conf` file).
        preCompileBuildDriver = ''
          cabalPackageId=$(basename --suffix=.conf ${fixedCabal}/lib/ghc-*/package.conf.d/*.conf)
          echo "Determined cabalPackageId as $cabalPackageId"

          setupCompileFlags="$setupCompileFlags -package-id $cabalPackageId"
        '';
      });

  issue_61682_throw = name: static_package:
    if approach == "pkgsStatic"
      then static_package
      else throw "If you see this, nixpkgs #61682 has been fixed and ${name} should be overridden";

  # Takes a zlib derivation and overrides it to have both .a and .so files.
  statify_zlib = zlib_drv:
    (zlib_drv.override {
      shared = true;
      static = true;
      splitStaticOutput = false;
    }).overrideAttrs (old: { dontDisableStatic = true; });

  # Takes a curl derivation and overrides it to have both .a and .so files,
  # and have the `curl` executable be statically linked.
  statify_curl_including_exe = curl_drv:
    (curl_drv.override (old: {
      # Disable gss support, because that requires `krb5`, which
      # (as mentioned in note [krb5 can only be static XOR shared]) is a
      # library that cannot build both .a and .so files in its build system.
      # That means that if we enable it, we can no longer build the
      # dynamically-linked `curl` binary from the overlay
      # `archiveFilesOverlay` below where `statify_curl_including_exe` is used.
      gssSupport = false;
      zlib = statify_zlib old.zlib;
    })).overrideAttrs (old: {
      dontDisableStatic = true;

      # Additionally, flags to also build a static `curl` executable:

      # Note: It is important that in the eventual `libtool` invocation,
      # `-all-static` comes before (or instead of) `-static`.
      # This is because the first of them "wins setting the mode".
      # See https://lists.gnu.org/archive/html/libtool/2006-12/msg00047.html
      # libtool makes various problems with static linking.
      # Some of them are is well-described by
      #   https://github.com/sabotage-linux/sabotage/commit/57a989a2e23c9e46501da1227f371da59d212ae4
      # However, so far, `-all-static` seems to have the same effect
      # of convincing libtool to NOT drop the `-static` flag.
      # Other places where this was dicussed (in case you have to debug this in
      # the future) are:
      #   https://debbugs.gnu.org/cgi/bugreport.cgi?bug=11064
      #   https://github.com/esnet/iperf/issues/632
      # Another common thing that people do is to pass `-static --static`,
      # with the intent that `--static` isn't eaten by libtool but still
      # accepted by e.g. gcc. In our case as of writing (nixpkgs commit bc94dcf50),
      # this isn't enough. That is because:
      #   * The `--with-*=/path` options given to curl's `./configure`
      #     are usually `.lib` split outputs that contain only headers and
      #     pkg-config `.pc` files. OK so far.
      #   * For some of these, e.g. for libssh2, curl's `./configure` turns them
      #     into `LDFLAGS=-L/...libssh2-dev/lib`, which doesn't do anything to
      #     libtool, gcc or ld, because `*-dev/lib` contains only `lib/pkgconfig`
      #     and no libraries.
      #   * But for others, e.g. for libnghttp2, curl's `./configure` resolves
      #     them by taking the actual `-L` flags out of the `.pc` file, and turns
      #     them into e.g. `LDFLAGS=-L/...nghttp2-lib/lib`, which contains
      #     `{ *.la, *.a, *.so }`.
      #   * When libtool is invoked with such `LDFLAGS`, it adds two entries to
      #     `./lib/libcurl.la`'s `dependency_libs=`: `-L/...nghttp2-lib/lib` and
      #     `/...nghttp2-lib/lib/*.la`.
      #     When the `.la` path is given, libtool will read it, and pass the
      #     `.so` file referred to within as a positional argument to e.g. gcc,
      #     even when linking statically, which will result in linker error
      #         ld: attempted static link of dynamic object `/...-nghttp2-lib/lib/libnghttp2.so'
      #     I believe this is what
      #         https://github.com/sabotage-linux/sabotage/commit/57a989a2e23c9e46501da1227f371da59d212ae4
      #     fixes.
      # If we pass `-all-static` to libtool, it won't do the things in the last
      # bullet point, causing static linking to succeed.
      makeFlags = [ "curl_LDFLAGS=-all-static" ];
    });

  # Overlay that enables `.a` files for as many system packages as possible.
  # This is in *addition* to `.so` files.
  # See also https://github.com/NixOS/nixpkgs/issues/61575
  # TODO Instead of overriding each individual package manually,
  #      override them all at once similar to how `makeStaticLibraries`
  #      in `adapters.nix` does it (but without disabling shared).
  archiveFilesOverlay = final: previous: {

    libffi = previous.libffi.overrideAttrs (old: { dontDisableStatic = true; });

    sqlite = previous.sqlite.overrideAttrs (old: { dontDisableStatic = true; });

    lzma = previous.lzma.overrideAttrs (old: { dontDisableStatic = true; });

    # Note [Packages that can't be overridden by overlays]
    # TODO: Overriding the packages mentioned here has no effect in overlays.
    #       This is because of https://github.com/NixOS/nixpkgs/issues/61682.
    #       That's why we make up new package names with `_static` at the end,
    #       and explicitly give them to packages or as linker flags in `statify`.
    #       See also that link for the total list of packages that have this problem.
    #       As of original finding it is, as per `pkgs/stdenv/linux/default.nix`:
    #           gzip bzip2 xz bash coreutils diffutils findutils gawk
    #           gnumake gnused gnutar gnugrep gnupatch patchelf
    #           attr acl zlib pcre
    acl_static = previous.acl.overrideAttrs (old: { dontDisableStatic = true; });
    attr_static = previous.attr.overrideAttrs (old: { dontDisableStatic = true; });
    bash_static = previous.bash.overrideAttrs (old: { dontDisableStatic = true; });
    bzip2_static = previous.bzip2.overrideAttrs (old: { dontDisableStatic = true; });
    coreutils_static = previous.coreutils.overrideAttrs (old: { dontDisableStatic = true; });
    diffutils_static = previous.diffutils.overrideAttrs (old: { dontDisableStatic = true; });
    findutils_static = previous.findutils.overrideAttrs (old: { dontDisableStatic = true; });
    gawk_static = previous.gawk.overrideAttrs (old: { dontDisableStatic = true; });
    gnugrep_static = previous.gnugrep.overrideAttrs (old: { dontDisableStatic = true; });
    gnumake_static = previous.gnumake.overrideAttrs (old: { dontDisableStatic = true; });
    gnupatch_static = previous.gnupatch.overrideAttrs (old: { dontDisableStatic = true; });
    gnused_static = previous.gnused.overrideAttrs (old: { dontDisableStatic = true; });
    gnutar_static = previous.gnutar.overrideAttrs (old: { dontDisableStatic = true; });
    gzip_static = previous.gzip.overrideAttrs (old: { dontDisableStatic = true; });
    patchelf_static = previous.patchelf.overrideAttrs (old: { dontDisableStatic = true; });
    pcre_static = previous.pcre.overrideAttrs (old: { dontDisableStatic = true; });
    xz_static = previous.xz.overrideAttrs (old: { dontDisableStatic = true; });
    zlib_both = statify_zlib previous.zlib;
    # Also override the original packages with a throw (which as of writing
    # has no effect) so we can know when the bug gets fixed in the future.
    acl = issue_61682_throw "acl" previous.acl;
    attr = issue_61682_throw "attr" previous.attr;
    bash = issue_61682_throw "bash" previous.bash;
    bzip2 = issue_61682_throw "bzip2" previous.bzip2;
    coreutils = issue_61682_throw "coreutils" previous.coreutils;
    diffutils = issue_61682_throw "diffutils" previous.diffutils;
    findutils = issue_61682_throw "findutils" previous.findutils;
    gawk = issue_61682_throw "gawk" previous.gawk;
    gnugrep = issue_61682_throw "gnugrep" previous.gnugrep;
    gnumake = issue_61682_throw "gnumake" previous.gnumake;
    gnupatch = issue_61682_throw "gnupatch" previous.gnupatch;
    gnused = issue_61682_throw "gnused" previous.gnused;
    gnutar = issue_61682_throw "gnutar" previous.gnutar;
    gzip = issue_61682_throw "gzip" previous.gzip;
    patchelf = issue_61682_throw "patchelf" previous.patchelf;
    pcre = issue_61682_throw "pcre" previous.pcre;
    xz = issue_61682_throw "xz" previous.xz;
    # For unknown reason we can't do this check on `zlib`, because if we do, we get:
    #
    #   while evaluating the attribute 'zlib_static' at /home/niklas/src/haskell/static-haskell-nix/survey/default.nix:498:5:
    #   while evaluating the attribute 'zlib.override' at /home/niklas/src/haskell/static-haskell-nix/survey/default.nix:525:5:
    #   while evaluating 'issue_61682_throw' at /home/niklas/src/haskell/static-haskell-nix/survey/default.nix:455:29, called from /home/niklas/src/haskell/static-haskell-nix/survey/default.nix:525:12:
    #   If you see this, nixpkgs #61682 has been fixed and zlib should be overridden
    #
    # So somehow, the above `zlib_static` uses *this* `zlib`, even though
    # the above uses `previous.zlib.override` and thus shouldn't see this one.
    #zlib = issue_61682_throw "zlib" previous.zlib;

    postgresql = (previous.postgresql.overrideAttrs (old: { dontDisableStatic = true; })).override {
      # We need libpq, which does not need systemd,
      # and systemd doesn't currently build with musl.
      enableSystemd = false;
    };

    pixman = previous.pixman.overrideAttrs (old: { dontDisableStatic = true; });
    fontconfig = previous.fontconfig.overrideAttrs (old: {
      dontDisableStatic = true;
      configureFlags = (old.configureFlags or []) ++ [
        "--enable-static"
      ];
    });
    cairo = previous.cairo.overrideAttrs (old: { dontDisableStatic = true; });

    expat = previous.expat.overrideAttrs (old: { dontDisableStatic = true; });

    mpfr = previous.mpfr.overrideAttrs (old: { dontDisableStatic = true; });

    gmp = previous.gmp.overrideAttrs (old: { dontDisableStatic = true; });

    gsl = previous.gsl.overrideAttrs (old: { dontDisableStatic = true; });

    libxml2 = previous.libxml2.overrideAttrs (old: { dontDisableStatic = true; });

    nettle = previous.nettle.overrideAttrs (old: { dontDisableStatic = true; });

    nghttp2 = previous.nghttp2.overrideAttrs (old: { dontDisableStatic = true; });

    libssh2 = (previous.libssh2.overrideAttrs (old: { dontDisableStatic = true; }));

    keyutils = previous.keyutils.overrideAttrs (old: { dontDisableStatic = true; });

    libxcb = previous.xorg.libxcb.overrideAttrs (old: { dontDisableStatic = true; });
    libX11 = previous.xorg.libX11.overrideAttrs (old: { dontDisableStatic = true; });
    libXext = previous.xorg.libXext.overrideAttrs (old: { dontDisableStatic = true; });
    libXinerama = previous.xorg.libXinerama.overrideAttrs (old: { dontDisableStatic = true; });
    libXrandr = previous.xorg.libXrandr.overrideAttrs (old: { dontDisableStatic = true; });
    libXrender = previous.xorg.libXrender.overrideAttrs (old: { dontDisableStatic = true; });
    libXScrnSaver = previous.xorg.libXScrnSaver.overrideAttrs (old: { dontDisableStatic = true; });
    libXau = previous.xorg.libXau.overrideAttrs (old: { dontDisableStatic = true; });
    libXdmcp = previous.xorg.libXdmcp.overrideAttrs (old: { dontDisableStatic = true; });

    openblas = previous.openblas.override { enableStatic = true; };

    openssl = previous.openssl.override { static = true; };

    krb5 = previous.krb5.override {
      # Note [krb5 can only be static XOR shared]
      # krb5 does not support building both static and shared at the same time.
      # That means *anything* on top of this overlay trying to link krb5
      # dynamically from this overlay will fail with linker errors.
      staticOnly = true;
    };

    # See comments on `statify_curl_including_exe` for the interaction with krb5!
    curl = statify_curl_including_exe previous.curl;

    # TODO: All of this can be removed once https://github.com/NixOS/nixpkgs/pull/66506
    #       is available.
    # Given that we override `krb5` (above) in this overlay so that it has
    # static libs only, the `curl` used by `fetchurl` (e.g. via `fetchpatch`,
    # which some packages may use) cannot be dynamically linked against it.
    # Note this `curl` via `fetchurl` is NOT EXACTLY the same curl as our `curl` above
    # in the overlay, but has a peculiarity:
    # It forces `gssSupport = true` on Linux, undoing us setting it to `false` above!
    # See https://github.com/NixOS/nixpkgs/blob/73493b2a2df75b487c6056e577b6cf3e6aa9fc91/pkgs/top-level/all-packages.nix#L295
    # So we have to turn it back off again here, *inside* `fetchurl`.
    # Because `fetchurl` is a form of boostrap package,
    # (which make ssense, as `curl`'s source code itself must be fetchurl'd),
    # we can't just `fetchurl.override { curl = the_curl_from_the_overlay_above; }`;
    # that would give an infinite evaluation loop.
    # Instead, we have override the `curl` *after* `all-packages.nix` has force-set
    # `gssSupport = false`.
    # Other alternatives are to just use a statically linked `curl` binary for
    # `fetchurl`, or to keep `gssSupport = true` and give it a `krb5` that has
    # static libs switched off again.
    #
    # Note: This needs the commit from https://github.com/NixOS/nixpkgs/pull/66503 to work,
    # which allows us to do `fetchurl.override`.
    fetchurl = previous.fetchurl.override (old: {
      curl =
        # We have the 3 choices mentioned above:

        # 1) Turning `gssSupport` back off:

        (old.curl.override { gssSupport = false; }).overrideAttrs (old: {
          makeFlags = builtins.filter (x: x != "curl_LDFLAGS=-all-static") (old.makeFlags or []);
        });

        # 2) Static `curl` binary:

        # statify_curl old.curl;

        # 3) Non-statick krb5:

        # (old.curl.override (old: {
        #   libkrb5 = old.libkrb5.override { staticOnly = false; };
        # })).overrideAttrs (old: {
        #   makeFlags = builtins.filter (x: x != "curl_LDFLAGS=-all-static") old.makeFlags;
        # });
    });
  };


  pkgsWithArchiveFiles = pkgs.extend archiveFilesOverlay;


  # This overlay "fixes up" Haskell libraries so that static linking works.
  # See note "Don't add new packages here" below!
  haskellLibsReadyForStaticLinkingOverlay = final: previous:
    let
      previousHaskellPackages =
        if integer-simple
          # Note we don't have to set the `-finteger-simple` flag for packages that GHC
          # depends on (e.g. text), because nix + GHC already do this for us:
          #   https://github.com/ghc/ghc/blob/ghc-8.4.3-release/ghc.mk#L620-L626
          #   https://github.com/peterhoeg/nixpkgs/commit/50050f3cc9e006daa6800f15a29e258c6e6fa4b3#diff-2f6f8fd152c14d37ebd849aa6382257aR35
          then previous.haskell.packages.integer-simple."${compiler}"
          else previous.haskell.packages."${compiler}";
    in
      {
        haskellPackages = previousHaskellPackages.override (old: {
          overrides = final.lib.composeExtensions (old.overrides or (_: _: {})) (self: super:
            with final.haskell.lib;
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
                    # Note: Assigning the `pkg-config` output to a variable instead of
                    # substituting it directly in the `for` loop so that `set -e` caches
                    # when it fails.
                    # See https://unix.stackexchange.com/questions/23026/how-can-i-get-bash-to-exit-on-backtick-failure-in-a-similar-way-to-pipefail/23099#23099
                    # This was a bug for long where we didn't notice; shell is unsafe garbage.
                    ''
                      set -e

                      PKGCONFIG_OUTPUT=$(pkg-config --static ${pkgconfigFlagsString})

                      configureFlags+=$(for flag in $PKGCONFIG_OUTPUT; do echo -n " --ld-option=$flag"; done)
                    ''
                  ];
                  # TODO Somehow change nixpkgs (the generic haskell builder?) so that
                  # putting `curl_static` into `libraryPkgconfigDepends` is enough
                  # and the manual modification of `configureFlags` is not necessary.
                  libraryPkgconfigDepends = (old.libraryPkgconfigDepends or []) ++ pkgConfigNixPackages;
                });

                callCabal2nix =
                  final.haskellPackages.callCabal2nix;

                add_integer-simple_if_needed = haskellPkgs: haskellPkgs // (
                  # If the `integer-simple` flag is given, and there isn't already
                  # an `integer-simple` in the Haskell package set, add one as `null`.
                  # This works around the problem that `stack2nix`-generated Haskell
                  # package sets lack the `integer-simple` entries, even when everything
                  # is compiled with integer-simple, which leads to
                  #   Setup: Encountered missing dependencies:
                  #   integer-simple
                  # This PR fixes it in stack2nix:
                  #   https://github.com/input-output-hk/stack2nix/pull/167
                  # We still maintain the addition here so that users can use upstream
                  # `stack2nix` without problems.
                  if integer-simple && !(builtins.hasAttr "integer-simple" haskellPkgs) then {
                    integer-simple = null;
                  } else {});

            in add_integer-simple_if_needed {

              # This overrides settings for all Haskell packages.
              mkDerivation = attrs: super.mkDerivation (attrs // {

                # Disable haddocks to save time and because for some reason, haddock (e.g. for aeson)
                # fails with
                #     <command line>: can't load .so/.DLL for: libgmp.so (libgmp.so: cannot open shared object file: No such file or directory)
                # when we use `pkgsStatic`. Need to investigate.
                doHaddock = false;

                # Disable profiling to save build time.
                enableLibraryProfiling = false;
                enableExecutableProfiling = false;

                # If `disableOptimization` is on for fast iteration, pass `-O0` to GHC.
                # We use `buildFlags` instead of `configureFlags` so that it's
                # also in effect for packages which specify e.g.
                # `ghc-options: -O2` in their .cabal file.
                buildFlags = (attrs.buildFlags or []) ++
                  final.lib.optional disableOptimization "--ghc-option=-O0";
              });

              # Note:
              #
              #        Don't add new packages here.
              #
              # Only override existing ones in the minimal way possible.
              # This is for the use case that somebody passes us a Haskell package
              # set (e.g. generated with `stack2nix`) and just wants us to fix
              # up all their packages so that static linking works.
              # If we unconditionally add packages here, we will override
              # whatever packages they've passed us in.

              # Override zlib Haskell package to use the system zlib package
              # that has `.a` files added.
              # This is because the system zlib package can't be overridden accordingly,
              # see note [Packages that can't be overridden by overlays].
              zlib = super.zlib.override { zlib = final.zlib_both; };

              # `criterion`'s test suite fails with a timeout if its dependent
              # libraries (apparently `bytestring`) are compiled with `-O0`.
              # Even increasing the timeout 5x did not help!
              criterion =
                (if disableOptimization then dontCheck else lib.id)
                  super.criterion;

              # `double-conversion`'s test suite fails when `-O0` is used
              # because `realToFrac NaN /= NaN` on `-O0` (Haskell does not
              # provide a reasonable way to convert `Double -> CDouble`,
              # totally bonkers).
              # See https://github.com/bos/double-conversion/issues/26
              double-conversion =
                (if disableOptimization then dontCheck else lib.id)
                  super.double-conversion;

              blaze-textual =
                let
                  # `blaze-textual`'s implementation is wrong when `-O0` is used,
                  # see https://github.com/bos/blaze-textual/issues/11.
                  # If we did `disableOptimization`, re-enable it for this package.
                  # TODO Remove this when https://github.com/bos/blaze-textual/pull/12 is merged and in nixpkgs.
                  handleDisableOptimisation = drv:
                    if disableOptimization
                      then appendBuildFlag drv "--ghc-option=-O"
                      else drv;
                  # `blaze-textual` has a flag that needs to be given explicitly
                  # if `integer-simple` is to be used.
                  # TODO Put this into the `integer-simple` compiler set in nixpkgs? In:
                  #          https://github.com/NixOS/nixpkgs/blob/ef89b398/pkgs/top-level/haskell-packages.nix#L184
                  handleIntegerSimple = drv:
                    if integer-simple
                      then enableCabalFlag drv "integer-simple"
                      else drv;
                in handleIntegerSimple (handleDisableOptimisation super.blaze-textual);

              # `weigh`'s test suite fails when `-O0` is used
              # because that package inherently relies on optimisation to be on.
              weigh =
                (if disableOptimization then dontCheck else lib.id)
                  super.weigh;

              # `HsOpenSSL` has a bug where assertions are only triggered on `-O0`.
              # This breaks its test suite.
              # https://github.com/vshabanov/HsOpenSSL/issues/44
              HsOpenSSL =
                (if disableOptimization then dontCheck else lib.id)
                  super.HsOpenSSL;

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
                  then ( # Example package where this matters: `focuslist`
                    # See note [When Cabal is `null` in a package set].
                    # Also note we can't just use `buildPlatformHaskellPackagesWithFixedCabal.Cabal`
                    # here because that one may have different dependencies
                    # (e.g. `text` may have been overridden here but not there),
                    # which would lead to the
                    #   This package indirectly depends on multiple versions of the same package
                    # warning.
                    if builtins.isNull super.Cabal
                      # Note this addition is an exception to the "Don't add new packages here"
                      # rule from above, and we only do it if Cabal is not yet
                      # in the package set.
                      then applyPatchesToCabalDrv super."${defaultCabalPackageVersionComingWithGhc}"
                      else applyPatchesToCabalDrv super.Cabal
                    )
                  else super.Cabal; # `pkgsStatic` does not need that

              # Helpers for other packages

              hpc-coveralls = appendPatch super.hpc-coveralls (builtins.fetchurl https://github.com/guillaume-nargeot/hpc-coveralls/pull/73/commits/344217f513b7adfb9037f73026f5d928be98d07f.patch);

              conduit-extra =
                # TODO Remove this once we no longer care about conduit-extra < 1.3.1.1.
                #   Test-suite failing nondeterministically, see https://github.com/snoyberg/conduit/issues/385
                # I've already checked that it's fixed on 1.3.1.1; we just keep this
                # for a while longer for `stack2nix` users.
                (if final.lib.versionOlder super.conduit-extra.version "1.3.1.1" then dontCheck else lib.id)
                  super.conduit-extra;

              # See https://github.com/hslua/hslua/issues/67
              # It's not clear if it's safe to disable this as key functionality may be broken
              hslua = dontCheck super.hslua;

              # Test suite tries to connect to dbus, can't work in sandbox.
              credential-store = dontCheck super.credential-store;

              # Test suite calls all kinds of shell unilities, can't work in sandbox.
              dotenv = dontCheck super.dotenv;

              # Single test suite failure:
              #     set;get socket option (Pub):            FAIL
              #       *** Failed! Exception: 'ZMQError { errno = 22, source = "setByteStringOpt", message = "Invalid argument" }' (after 1 test):
              #       ZapDomain (Restricted "")
              #       Use --quickcheck-replay=307313 to reproduce.
              zeromq4-haskell = dontCheck super.zeromq4-haskell;

              # Fails in doctests with:
              #     doctests: /nix/store/v5lw9170rw5s9vm69qsmd5ybns7yv2dj-ghc-8.6.4/lib/ghc-8.6.4/ghc-prim-0.5.3/HSghc-prim-0.5.3.o: unknown symbol `exp'
              #     doctests: doctests: unable to load package `ghc-prim-0.5.3'
              lens-regex = dontCheck super.lens-regex;

              # Fails in doctests with:
              #     focuslist-doctests: /nix/store/v5lw9170rw5s9vm69qsmd5ybns7yv2dj-ghc-8.6.4/lib/ghc-8.6.4/ghc-prim-0.5.3/HSghc-prim-0.5.3.o: unknown symbol `exp'
              #     focuslist-doctests: focuslist-doctests: unable to load package `ghc-prim-0.5.3'
              focuslist = dontCheck super.focuslist;

              # Disabling test suite because it takes extremely long (> 30 minutes):
              # https://github.com/mrkkrp/zip/issues/55
              zip = dontCheck super.zip;

              # Override libs explicitly that can't be overridden with overlays.
              # See note [Packages that can't be overridden by overlays].
              regex-pcre = super.regex-pcre.override { pcre = final.pcre_static; };
              pcre-light = super.pcre-light.override { pcre = final.pcre_static; };
              bzlib-conduit = super.bzlib-conduit.override { bzip2 = final.bzip2_static; };

              darcs =
                addStaticLinkerFlagsWithPkgconfig
                  # (super.darcs.override { curl = curl_static; })
                  super.darcs
                  [ final.curl ]
                  # Ideally we'd like to use
                  #   pkg-config --static --libs libcurl
                  # but that doesn't work because that output contains `-Wl,...` flags
                  # which aren't accepted by `ld` and thus cannot be passed as `ld-option`s.
                  # See https://github.com/curl/curl/issues/2775 for an investigation of why.
                  "--libs-only-L --libs-only-l libcurl";

              # For https://github.com/BurntSushi/erd/issues/40
              # As of writing, not in Stackage.
              # Currently fails with linker error, see `yesod-paginator` below.
              erd = doJailbreak super.erd;

              hmatrix = ((drv: enableCabalFlag drv "no-random_r") (overrideCabal super.hmatrix (old: {
                # The patch does not apply cleanly because the cabal file
                # was Hackage-revisioned, which converted it to Windows line endings
                # (https://github.com/haskell-numerics/hmatrix/issues/302);
                # convert it back.
                prePatch = (old.prePatch or "") + ''
                  ${final.dos2unix}/bin/dos2unix ${old.pname}.cabal
                '';
                patches = (old.patches or []) ++ [
                  (final.fetchpatch {
                    url = "https://github.com/nh2/hmatrix/commit/e9da224bce287653f96235bd6ae02da6f8f8b219.patch";
                    name = "hmatrix-Allow-disabling-random_r-usage-manually.patch";
                    sha256 = "1fpv0y5nnsqcn3qi767al694y01km8lxiasgwgggzc7816xix0i2";
                    stripLen = 2;
                  })
                ];
              }))).override { openblasCompat = final.openblasCompat; };

              # TODO For the below packages, it would be better if we could somehow make all users
              # of postgresql-libpq link in openssl via pkgconfig.
              postgresql-schema =
                addStaticLinkerFlagsWithPkgconfig
                  super.postgresql-schema
                  [ final.openssl ]
                  "--libs openssl";
              postgresql-simple-migration =
                addStaticLinkerFlagsWithPkgconfig
                  super.postgresql-simple-migration
                  [ final.openssl ]
                  "--libs openssl";
              squeal-postgresql =
                addStaticLinkerFlagsWithPkgconfig
                  super.squeal-postgresql
                  [ final.openssl ]
                  "--libs openssl";

              xml-to-json =
                addStaticLinkerFlagsWithPkgconfig
                  super.xml-to-json
                  [ final.curl final.expat ]
                  # Ideally we'd like to use
                  #   pkg-config --static --libs libcurl
                  # but that doesn't work because that output contains `-Wl,...` flags
                  # which aren't accepted by `ld` and thus cannot be passed as `ld-option`s.
                  # See https://github.com/curl/curl/issues/2775 for an investigation of why.
                  "--libs-only-L --libs-only-l libcurl expat";

              # This package's dependency `rounded` currently fails its test with a patterm match error.
              aern2-real =
                addStaticLinkerFlagsWithPkgconfig
                  super.aern2-real
                  [ final.mpfr final.gmp ]
                  "--libs mpfr gmp";

              hopenpgp-tools =
                addStaticLinkerFlagsWithPkgconfig
                  super.hopenpgp-tools
                  [ final.nettle final.bzip2 ]
                  "--libs nettle bz2";

              # Added for #14
              tttool = callCabal2nix "tttool" (final.fetchFromGitHub {
                owner = "entropia";
                repo = "tip-toi-reveng";
                rev = "f83977f1bc117f8738055b978e3cfe566b433483";
                sha256 = "05bbn63sn18s6c7gpcmzbv4hyfhn1i9bd2bw76bv6abr58lnrwk3";
              }) {};

              # Override yaml on old versions to fix https://github.com/NixOS/cabal2nix/issues/372.
              # I've checked that versions >= 0.11.0.0 in nixpkgs on ghc864 don't need this
              # but `yaml-0.8.32` on ghc844 still does.
              yaml =
                if final.lib.versionOlder super.yaml.version "0.11.0.0"
                  then disableCabalFlag super.yaml "system-libyaml"
                  else super.yaml;

              # TODO Find out why these overrides are necessary, given that they all come from `final`
              #      (somehow without them, xmonad gives linker errors).
              #      Most likely it is because the `libX*` packages are available once on the top-level
              #      namespace (where we override them), and once under `xorg.libX*`, where we don't
              #      override them; it seems that `X11` depends on the latter.
              X11 = super.X11.override {
                libX11 = final.libX11;
                libXext = final.libXext;
                libXinerama = final.libXinerama;
                libXrandr = final.libXrandr;
                libXrender = final.libXrender;
                libXScrnSaver = final.libXScrnSaver;
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
                  (with final; [ xorg.libpthreadstubs libxcb libXau libXrender libXdmcp ])
                  "--libs xcb xau xrender xdmcp") [
                ];

              leveldb-haskell =
                appendConfigureFlag super.leveldb-haskell [
                  # Similar to https://github.com/nh2/static-haskell-nix/issues/10
                  "--ld-option=-Wl,--start-group --ld-option=-Wl,-lstdc++"
                ];

              zeromq4-patterns =
                dontCheck # test suite hangs forever
                  (appendConfigureFlag super.zeromq4-patterns [
                    # Similar to https://github.com/nh2/static-haskell-nix/issues/10
                    "--ld-option=-Wl,--start-group --ld-option=-Wl,-lstdc++"
                  ]);

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
      };


  pkgsWithHaskellLibsReadyForStaticLinking = pkgsWithArchiveFiles.extend haskellLibsReadyForStaticLinkingOverlay;


  # Overlay all Haskell executables are statically linked.
  staticHaskellBinariesOverlay = final: previous: {
    haskellPackages =
      let
          # We have to use `useFixedCabal` here, and cannot just rely on the
          # "Cabal = ..." we override up in `haskellPackagesWithLibsReadyForStaticLinking`,
          # because that `Cabal` isn't used in all packages:
          # If a package doesn't explicitly depend on the `Cabal` package, then
          # for compiling its `Setup.hs` the Cabal package that comes with GHC
          # (that is in the default GHC package DB) is used instead, which
          # obviously doesn' thave our patches.
          statify = drv: with final.haskell.lib; final.lib.foldl appendConfigureFlag (disableLibraryProfiling (disableSharedExecutables (useFixedCabal drv))) ([
            "--enable-executable-static" # requires `useFixedCabal`
            "--extra-lib-dirs=${final.ncurses.override { enableStatic = true; }}/lib"
          # TODO Figure out why this and the below libffi are necessary.
          #      `working` and `workingStackageExecutables` don't seem to need that,
          #      but `static-stack2nix-builder-example` does.
          ] ++ final.lib.optionals (!integer-simple) [
            "--extra-lib-dirs=${final.gmp6.override { withStatic = true; }}/lib"
          ] ++ final.lib.optionals (!integer-simple && approach == "pkgsMusl") [
            # GHC needs this if it itself wasn't already built against static libffi
            # (which is the case in `pkgsStatic` only):
            "--extra-lib-dirs=${final.libffi}/lib"
          ]);
      in
        final.lib.mapAttrs (name: value:
          if (isProperHaskellPackage value && isExecutable value) then statify value else value
        ) previous.haskellPackages;
  };


  pkgsWithStaticHaskellBinaries = pkgsWithHaskellLibsReadyForStaticLinking.extend staticHaskellBinariesOverlay;


  # Legacy names
  haskellPackagesWithLibsReadyForStaticLinking = pkgsWithHaskellLibsReadyForStaticLinking.haskellPackages;
  haskellPackages = pkgsWithStaticHaskellBinaries.haskellPackages;



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
        aura # Removed for now as it keeps having Cabal bounds issues (https://github.com/aurapm/aura/issues/526#issuecomment-493716675)
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
        "csg"
        "cuda" # transitively depends on `systemd`, which doesn't build with musl
        "debug"
        "diagrams-builder"
        "ersatz"
        "gloss-examples" # needs opengl
        "gtk3" # problem compiling `glib` dependency with `Distribution.Simple.UserHooks.UserHooks` type mismatch across Cabal versions; should go away once we no longer have to patch Cabal
        "hamilton" # openmp linker error via openblas
        "hquantlib"
        "ihaskell"
        "jack" # transitively depends on `systemd`, which doesn't build with musl
        "LambdaHack"
        "language-puppet" # dependency `hruby` does not build
        "learn-physics"
        "leveldb-haskell"
        "odbc" # undeclared `<odbcss.h>` dependency
        "OpenAL" # transitively depends on `systemd`, which doesn't build with musl
        "qchas" # openmp linker error via openblas
        "sdl2" # transitively depends on `systemd`, which doesn't build with musl
        "sdl2-gfx" # see `sdl2`
        "sdl2-image" # see `sdl2`
        "sdl2-mixer" # see `sdl2`
        "sdl2-ttf" # see `sdl2`
        "soxlib" # transitively depends on `systemd`, which doesn't build with musl
        "yesod-paginator" # some `curl` build failure; seems to be in *fetching* the source .tar.gz in `fetchurl`, and gss is enabled there even though we tried to disable it
      ];

    inherit normalPkgs;
    approachPkgs = pkgs;
    # Export as `pkgs` our final overridden nixpkgs.
    pkgs = pkgsWithStaticHaskellBinaries;

    inherit lib;

    inherit pkgsWithArchiveFiles;
    inherit pkgsWithStaticHaskellBinaries;

    inherit haskellPackagesWithFailingStackageTestsDisabled;
    inherit haskellPackagesWithLibsReadyForStaticLinking;
    inherit haskellPackages;
  }
