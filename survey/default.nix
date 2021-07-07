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

  normalPkgs ? import ../nixpkgs.nix,

  overlays ? [],

  approach ? # "pkgsMusl" or "pkgsStatic"
    # TODO `pkgsStatic` support is currently not maintained and will likely be removed,
    #      because `pkgsMusl` is a better base for what we need.
    #      See https://github.com/NixOS/nixpkgs/issues/61575
    # TODO Find out why `pkgsStatic` creates ~3x larger binaries.
    "pkgsMusl", # does not exercise cross compilation
    # "pkgsStatic", # exercises cross compilation

  # Note that we must NOT use something like `import normalPkgs.path {}`.
  # It is bad because it removes previous overlays.
  pkgs ? (normalPkgs.appendOverlays [
    cython-disable-tests-overlay
  ])."${approach}",

  # When changing this, also change the default version of Cabal declared below
  compiler ? "ghc8104",

  # See https://www.haskell.org/cabal/download.html section "Older Releases".
  defaultCabalPackageVersionComingWithGhc ?
    ({
      ghc822 = "Cabal_2_2_0_1"; # TODO this is technically incorrect for ghc 8.2.2, should be 2.0.1.0, but nixpkgs doesn't have that
      ghc844 = "Cabal_2_2_0_1";
      ghc863 = throw "static-haskell-nix: ghc863 is no longer supported, please upgrade";
      ghc864 = throw "static-haskell-nix: ghc864 is no longer supported, please upgrade";
      ghc865 = "Cabal_2_4_1_0"; # TODO this is technically incorrect for ghc 8.6.5, should be 2.4.0.1, but nixpkgs doesn't have that
      ghc881 = "Cabal_3_0_0_0";
      ghc8104 = "Cabal_3_2_1_0";
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
  mkBrokenPackagesMap = pkg: brokenPackagesMap0:
    assert pkg != null;
    if !(isProperHaskellPackage pkg) || builtins.hasAttr pkg.name brokenPackagesMap0 then brokenPackagesMap0 else if isBroken pkg then (brokenPackagesMap0 // { ${pkg.name} = "broken"; }) else builtins.trace "mkBrokenPackagesMap ${pkg.name} -- ${toString (builtins.attrNames pkg)}"
(    let
      brokenPackagesMap = brokenPackagesMap0 // { ${pkg.name} = "entered"; };
      # Build the set of Haskell packages that this package depends on,
      # by cabal-overriding (so we can access `drv`), and putting the
      # desired information into `passthru`.
      haskellDepends =
        (pkgs.haskell.lib.overrideCabal pkg (drv: {
          passthru.anyHaskellDepends = builtins.concatLists [
            (drv.libraryHaskellDepends or [])
            (drv.executableHaskellDepends or [])
            (drv.testHaskellDepends or [])
            (drv.benchmarkHaskellDepends or [])
          ];
        })).anyHaskellDepends;
    in
      (newBrokenPackagesMap:
        let
          anyDepIsBroken =
            lib.any
              (dep:
                # builtins.trace "anyDepIsBroken dep ${dep.name}"
                (if !(isProperHaskellPackage dep) || !(builtins.hasAttr dep.name newBrokenPackagesMap)
                  then false
                  else
                    builtins.trace "${dep.name} x-> ${newBrokenPackagesMap.${dep.name}}"
                         (newBrokenPackagesMap.${dep.name} == "broken")
                )
              )
              (lib.filter (x: x != null) haskellDepends);
        in
        builtins.trace
         # "broken ${builtins.toJSON x}: ${pkg.name}: ${builtins.toJSON (map (p: p.name or "") haskellDepends)}; brokenPackagesMap = ${builtins.toJSON brokenPackagesMap}"
         "deps of ${pkg.name}: ${builtins.toJSON (map (p: if !(p?name) then "" else [p.name (newBrokenPackagesMap.${p.name} or "np")]) haskellDepends)}; anyDepIsBroken = ${builtins.toJSON anyDepIsBroken}"
         (if anyDepIsBroken
            then (newBrokenPackagesMap // { ${pkg.name} = "broken"; })
            else (newBrokenPackagesMap // { ${pkg.name} = "not-broken"; })
          )
      )
      (builtins.foldl'
        (brokenPackagesMap: x: # if isBroken x then (brokenPackagesMap // { ${x.name} = "broken"; }) else if !(isProperHaskellPackage x) then brokenPackagesMap else
          let
            res = builtins.trace "going over ${x.name} as dep of ${pkg.name}; attrs: ${toString (builtins.attrNames x)}" builtins.tryEval (isBroken x);
          in
            if !res.success || !(lib.isDerivation x)
              then brokenPackagesMap
              else
                # if builtins.trace "xx ${x.name}" (builtins.trace "xy ${builtins.toJSON (isProperHaskellPackage x)}" (!(isProperHaskellPackage x)))
                #   then brokenPackagesMap
                #   else
                    let
                      broken = res.value;
                    in
                      if builtins.trace "xz ${x.name} broken ${toString broken}" broken
                        then builtins.trace "broken deps: ${pkg.name}" (brokenPackagesMap // { ${x.name} = "broken"; })
                        else
                          let
                            res2 = mkBrokenPackagesMap x brokenPackagesMap;
                            newBrokenPackagesMap = res2;
                            recursivelyBroken = if (builtins.hasAttr x.name newBrokenPackagesMap) then newBrokenPackagesMap.${x.name} == "broken" else false;
                          in
                            if
                                builtins.trace
                                  "checking ${x.name or ""}; broken = ${builtins.toJSON broken}; recursivelyBroken = ${builtins.toJSON recursivelyBroken}"
                                  recursivelyBroken
                              then builtins.trace "broken because of broken deps: ${pkg}" (newBrokenPackagesMap // { ${x.name} = "broken"; })
                              else newBrokenPackagesMap
        )
        brokenPackagesMap
        (lib.filter (x: x != null) haskellDepends)
       )
      );

  # Turn e.g. `Cabal_1_2_3_4` into `1.2.3.4`.
  cabalDottedVersion =
    builtins.replaceStrings ["_"] ["."]
      (builtins.substring
        (builtins.stringLength "Cabal_")
        (builtins.stringLength defaultCabalPackageVersionComingWithGhc)
        defaultCabalPackageVersionComingWithGhc
      );

  areCabalPatchesRequired =
    builtins.length (requiredCabalPatchesList cabalDottedVersion) != 0;

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
      stackageInfoPath = pkgs.path + "/pkgs/development/haskell-modules/configuration-hackage2nix/stackage.yaml";
      pythonWithYaml = pkgs.python2Packages.python.withPackages (pkgs: [pkgs.pyyaml]);
      stackage-packages-file = normalPkgs.runCommand "stackage-packages" {} ''
        ${pythonWithYaml}/bin/python -c 'import yaml, json; x = yaml.load(open("${stackageInfoPath}")); print(json.dumps([line.split(" ")[0] for line in x["default-package-overrides"]]))' > $out
      '';
      stackage-packages = builtins.fromJSON (builtins.readFile stackage-packages-file);
    in
      stackage-packages;

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
            # Currently all our Cabal patches are upstreamed, so this is technically
            # not necessary currently; however, we keep this infrastructure in case
            # we need to patch Cabal again in the future.
            #
            # If there are no patches to apply, keep original Cabal,
            # even if `null` (to get the one that comes with GHC).
            if not areCabalPatchesRequired
              then super.Cabal
              else
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

      stackageExecutables =
        let
          brokenPackagesMap = builtins.foldl' (brokenPackagesMap: pkg: if (pkg == null || !(isProperHaskellPackage pkg)) then brokenPackagesMap else mkBrokenPackagesMap pkg brokenPackagesMap) {} (builtins.attrValues normalHaskellPackages);
          # Predicate copied from nixpkgs' `transitive-broken-packages.nix`:
          isEvaluatingUnbroken v = (builtins.tryEval (v.outPath or null)).success && lib.isDerivation v && !v.meta.broken;
        in
        # builtins.trace "${builtins.toJSON brokenPackagesMap}"
        lib.filterAttrs
      #   (name: x: isStackagePackage name && !(lib.elem name blacklist) && (
      #   let
      #     res = builtins.tryEval (
      #          isProperHaskellPackage x
      #       && isExecutable x
      #       && !(isBroken x)
      #       && (brokenPackagesMap.${x.name} != "broken") ## TODO: assert that nothing in the map is "entered" at this point
      #     );
      #   in
      #     res.success && res.value
      #     )
      # )
          (name: v: (v != null && isStackagePackage name && !(lib.elem name blacklist) && isExecutable v && isEvaluatingUnbroken)
         normalHaskellPackages;

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

  # Returns the list of patches that a given cabal derivation needs to work well
  # for static building.
  requiredCabalPatchesList = cabalDottedVersionString:
    # Patches we know are merged in a certain cabal version
    # (we include them conditionally here anyway, for the case
    # that the user specifies a different Cabal version e.g. via
    # `stack2nix`):
    if pkgs.lib.versionOlder cabalDottedVersionString "3.0.0.0"
      then
        (builtins.concatLists [
          # -L flag deduplication
          #   https://github.com/haskell/cabal/pull/5356
          (lib.optional (pkgs.lib.versionOlder cabalDottedVersionString "2.4.0.0") (makeCabalPatch {
            name = "5356.patch";
            url = "https://github.com/haskell/cabal/commit/fd6ff29e268063f8a5135b06aed35856b87dd991.patch";
            sha256 = "1l5zwrbdrra789c2sppvdrw3b8jq241fgavb8lnvlaqq7sagzd1r";
          }))
        # Patches that as of writing aren't merged yet:
        ]) ++ [
          # TODO Move this into the above section when merged in some Cabal version:
          # --enable-executable-static
          #   https://github.com/haskell/cabal/pull/5446
          (if pkgs.lib.versionOlder cabalDottedVersionString "2.4.0.0"
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
          (if pkgs.lib.versionOlder cabalDottedVersionString "2.4.0.0"
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
        ]
      # cabal >= 3.0.0.0 currently needs no patches.
      else [];

  applyPatchesToCabalDrv = cabalDrv: pkgs.haskell.lib.overrideCabal cabalDrv (old: {
    patches = (old.patches or []) ++ requiredCabalPatchesList cabalDrv.version;
  });

  useFixedCabal = if !areCabalPatchesRequired then (drv: drv) else
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
  statify_curl_including_exe = curl_drv: zlib_both:
    (curl_drv.override (old: {
      # Disable gss support, because that requires `krb5`, which
      # (as mentioned in note [krb5 can only be static XOR shared]) is a
      # library that cannot build both .a and .so files in its build system.
      # That means that if we enable it, we can no longer build the
      # dynamically-linked `curl` binary from the overlay
      # `archiveFilesOverlay` below where `statify_curl_including_exe` is used.
      gssSupport = false;
      zlib = zlib_both;
    })).overrideAttrs (old: {
      dontDisableStatic = true;

      configureFlags = (old.configureFlags or []) ++ [
        "--enable-static"
        # Use environment variable to override the `pkg-config` command
        # to have `--static`, as even curl's `--enable-static` configure option
        # does not currently make it itself invoke `pkg-config` with that flag.
        # See: https://github.com/curl/curl/issues/503#issuecomment-150680789
        # While one would usually do
        #     PKG_CONFIG="pkg-config --static" ./configure ...
        # nix's generic stdenv builder does not support passing environment
        # variables before `./configure`, and doing `PKG_CONFIG = "false";`
        # as a nix attribute doesn't work either for unknown reasons
        # (it gets set in the `bash` executing the build, but something resets
        # it for the child process invocations); luckily, `./configure`
        # also accepts env variables at the end as arguments.
        # However, they apparently have to be single paths, so passing
        #     ./configure ... PKG_CONFIG="pkg-config --static"
        # does not work, so we use `writeScript` instead.
        #
        # (Personally I think that passing `--enable-static` to curl should
        # probably instruct it to pass `--static` to `pkg-config` itself.)
        "PKG_CONFIG=${pkgs.writeScript "pkgconfig-static-wrapper" "exec pkg-config --static $@"}"
      ];

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
    # [previously there were overrides here, but they stopped working, read below]
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
    # Similarly, we don't know why these are are evaluated, but it happens for
    # https://github.com/nh2/static-haskell-nix/issues/47.
    #bzip2 = issue_61682_throw "bzip2" previous.bzip2;
    #pcre = issue_61682_throw "pcre" previous.pcre;
    # Since the update to nixpkgs master for #61 also for these,
    # see https://github.com/NixOS/nixpkgs/issues/61682#issuecomment-544215621
    #acl = issue_61682_throw "acl" previous.acl;
    #attr = issue_61682_throw "attr" previous.attr;
    #bash = issue_61682_throw "bash" previous.bash;
    #coreutils = issue_61682_throw "coreutils" previous.coreutils;
    #diffutils = issue_61682_throw "diffutils" previous.diffutils;
    #findutils = issue_61682_throw "findutils" previous.findutils;
    #gawk = issue_61682_throw "gawk" previous.gawk;
    #gnugrep = issue_61682_throw "gnugrep" previous.gnugrep;
    #gnumake = issue_61682_throw "gnumake" previous.gnumake;
    #gnupatch = issue_61682_throw "gnupatch" previous.gnupatch;
    #gnused = issue_61682_throw "gnused" previous.gnused;
    #gnutar = issue_61682_throw "gnutar" previous.gnutar;
    #gzip = issue_61682_throw "gzip" previous.gzip;
    #patchelf = issue_61682_throw "patchelf" previous.patchelf;
    #xz = issue_61682_throw "xz" previous.xz;

    postgresql = (previous.postgresql.overrideAttrs (old: { dontDisableStatic = true; })).override {
      # We need libpq, which does not need systemd,
      # and systemd doesn't currently build with musl.
      enableSystemd = false;
    };

    procps = previous.procps.override {
      # systemd doesn't currently build with musl.
      withSystemd = false;
    };

    pixman = previous.pixman.overrideAttrs (old: { dontDisableStatic = true; });
    freetype = previous.freetype.overrideAttrs (old: { dontDisableStatic = true; });
    fontconfig = previous.fontconfig.overrideAttrs (old: {
      dontDisableStatic = true;
      configureFlags = (old.configureFlags or []) ++ [
        "--enable-static"
      ];
    });
    cairo = previous.cairo.overrideAttrs (old: { dontDisableStatic = true; });
    libpng = previous.libpng.overrideAttrs (old: { dontDisableStatic = true; });
    libpng_apng = previous.libpng_apng.overrideAttrs (old: { dontDisableStatic = true; });
    libpng12 = previous.libpng12.overrideAttrs (old: { dontDisableStatic = true; });
    libtiff = previous.libtiff.overrideAttrs (old: { dontDisableStatic = true; });
    libwebp = previous.libwebp.overrideAttrs (old: { dontDisableStatic = true; });

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
    libXau = previous.xorg.libXau.overrideAttrs (old: { dontDisableStatic = true; });
    libXcursor = previous.xorg.libXcursor.overrideAttrs (old: { dontDisableStatic = true; });
    libXdmcp = previous.xorg.libXdmcp.overrideAttrs (old: { dontDisableStatic = true; });
    libXext = previous.xorg.libXext.overrideAttrs (old: { dontDisableStatic = true; });
    libXfixes = previous.xorg.libXfixes.overrideAttrs (old: { dontDisableStatic = true; });
    libXi = previous.xorg.libXi.overrideAttrs (old: { dontDisableStatic = true; });
    libXinerama = previous.xorg.libXinerama.overrideAttrs (old: { dontDisableStatic = true; });
    libXrandr = previous.xorg.libXrandr.overrideAttrs (old: { dontDisableStatic = true; });
    libXrender = previous.xorg.libXrender.overrideAttrs (old: { dontDisableStatic = true; });
    libXScrnSaver = previous.xorg.libXScrnSaver.overrideAttrs (old: { dontDisableStatic = true; });
    libXxf86vm = previous.xorg.libXxf86vm.overrideAttrs (old: { dontDisableStatic = true; });

    SDL2 = previous.SDL2.overrideAttrs (old: { dontDisableStatic = true; });
    SDL2_gfx = previous.SDL2_gfx.overrideAttrs (old: { dontDisableStatic = true; });
    SDL2_image = previous.SDL2_image.overrideAttrs (old: { dontDisableStatic = true; });
    SDL2_mixer = previous.SDL2_mixer.overrideAttrs (old: { dontDisableStatic = true; });

    libjpeg = previous.libjpeg.override (old: { enableStatic = true; });
    libjpeg_turbo = previous.libjpeg_turbo.override (old: { enableStatic = true; });

    openblas = previous.openblas.override { enableStatic = true; };

    openssl = previous.openssl.override { static = true; };

    libsass = previous.libsass.overrideAttrs (old: { dontDisableStatic = true; });

    # Disabling kerberos support for now, as openssh's `./configure` fails to
    # detect its functions due to linker error, so the build breaks, see #68.
    openssh = previous.openssh.override { withKerberos = false; };

    krb5 = previous.krb5.override {
      # Note [krb5 can only be static XOR shared]
      # krb5 does not support building both static and shared at the same time.
      # That means *anything* on top of this overlay trying to link krb5
      # dynamically from this overlay will fail with linker errors.
      staticOnly = true;
    };

    # Brotli can currently build only static or shared libraries,
    # see https://github.com/google/brotli/pull/655#issuecomment-864395830
    brotli = previous.brotli.override { staticOnly = true; };

    # woff2 currently builds against the `brotli` static libs only with a patch
    # that's enabled by its `static` argument.
    woff2 = previous.woff2.override { static = true; };

    # See comments on `statify_curl_including_exe` for the interaction with krb5!
    # As mentioned in [Packages that can't be overridden by overlays], we can't
    # override zlib to have static libs, so we have to pass in `zlib_both` explicitly
    # so that `curl` can use it.
    curl = statify_curl_including_exe previous.curl final.zlib_both;

    # `fetchurl` uses our overridden `curl` above, but `fetchurl` overrides
    # `zlib` in `curl`, see
    # https://github.com/NixOS/nixpkgs/blob/4a5c0e029ddbe89aa4eb4da7949219fe4e3f8472/pkgs/top-level/all-packages.nix#L296-L299
    # so because of [Packages that can't be overridden by overlays],
    # it will undo our `zlib` override in `curl` done above (for `curl`
    # use via `fetchurl`).
    # So we need to explicitly put our zlib into that one's curl here.
    fetchurl = previous.fetchurl.override (old: {
      # Can't use `zlib_both` here (infinite recursion), so we
      # re-`statify_zlib` `final.zlib` here (interesting that
      # `previous.zlib` also leads to infinite recursion at time of writing).
      # We also disable kerberos (`gssSupport`) here again, because for
      # some unknown reason it sneaks back in.
      curl = old.curl.override { zlib = statify_zlib final.zlib; gssSupport = false; };
    });

    R = (previous.R.override {
      # R supports EITHER static or shared libs.
      static = true;
      # The Haskell package `H` depends on R, which pulls in OpenJDK,
      # which is not patched for musl support yet in nixpkgs.
      # Disable Java support for now.
      javaSupport = false;
    }).overrideAttrs (old: {
      # Testsuite newly seems to have at least one segfaulting test case.
      # Disable test suite for now; Alpine also does it:
      # https://git.alpinelinux.org/aports/tree/community/R/APKBUILD?id=e2bce14c748aacb867713cb81a91fad6e8e7f7f6#n56
      doCheck = false;
    });

    bash-completion = previous.bash-completion.overrideAttrs (old: {
      # Disable tests because it some of them seem dynamic linking specific:
      #     FAILED test/t/test_getconf.py::TestGetconf::test_1 - assert <CompletionResult...
      #     FAILED test/t/test_ldd.py::TestLdd::test_options - assert <CompletionResult []>
      doCheck = false;
    });

    # As of writing, emacs still doesn't build, erroring with:
    #    Segmentation fault      ./temacs --batch --no-build-details --load loadup bootstrap
    emacs = previous.emacs.override {
      # Requires librsvg (in Rust), which gives:
      #     missing bootstrap url for platform x86_64-unknown-linux-musl
      withX = false;
      withGTK3 = false; # needs to be disabled because `withX` is disabled above
      systemd = null; # does not build with musl
    };
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
        # Helper function to add pkg-config static lib flags to a Haskell derivation.
        # We put it directly into the `pkgs` package set so that following overlays
        # can use it as well if they want to.
        staticHaskellHelpers.addStaticLinkerFlagsWithPkgconfig = haskellDrv: pkgConfigNixPackages: pkgconfigFlagsString:
          with final.haskell.lib; overrideCabal (appendConfigureFlag haskellDrv [
            # Ugly alert: We use `--start-group` to work around the fact that
            # the linker processes `-l` flags in the order they are given,
            # so order matters, see
            #   https://stackoverflow.com/questions/11893996/why-does-the-order-of-l-option-in-gcc-matter
            # and GHC inserts these flags too early, that is in our case, before
            # the `-lcurl` that pulls in these dependencies; see
            #   https://github.com/haskell/cabal/pull/5451#issuecomment-406759839
            # TODO: This can be removed once we have GHC 8.10, due to my merged PR:
            #   https://gitlab.haskell.org/ghc/ghc/merge_requests/1589
            "--ld-option=-Wl,--start-group"
          ]) (old: {
            # We can't pass all linker flags in one go as `ld-options` because
            # the generic Haskell builder doesn't let us pass flags containing spaces.
            preConfigure = builtins.concatStringsSep "\n" [
              (old.preConfigure or "")
              # Note: Assigning the `pkg-config` output to a variable instead of
              # substituting it directly in the `for` loop so that `set -e` catches
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


        haskellPackages = previousHaskellPackages.override (old: {
          overrides = final.lib.composeExtensions (old.overrides or (_: _: {})) (self: super:
            with final.haskell.lib;
            with final.staticHaskellHelpers;
            let
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

                # Skip tests on -O0 because some tests are extremely slow on -O0.
                # This prevents us from finding upstream correctness issues that
                # appear only with -O0,
                # such as https://github.com/bos/double-conversion/issues/26
                # but that's OK for now as we want -O0 mainly for faster feedback.
                # doCheck = !disableOptimization;

                # If `disableOptimization` is on for fast iteration, pass `-O0` to GHC.
                # We use `buildFlags` instead of `configureFlags` so that it's
                # also in effect for packages which specify e.g.
                # `ghc-options: -O2` in their .cabal file.
                buildFlags = (attrs.buildFlags or []) ++
                  final.lib.optional disableOptimization "--ghc-option=-O0";

                # There is currently a 300x `strip` performance regression in
                # `binutils`, making some strips take 5 minutes instead of 1 second.
                # Disable stripping until it's solved:
                #     https://github.com/NixOS/nixpkgs/issues/129467
                #     https://sourceware.org/bugzilla/show_bug.cgi?id=28058
                dontStrip = true;
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

              # The `properties` test suite takes > 30 minutes with `-O0`.
              aeson-diff =
                (if disableOptimization then dontCheck else lib.id)
                  super.aeson-diff;

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

              # Test suite fails time-dependently:
              #     https://github.com/peti/cabal2spec/commit/6078778c06be45eb468f4770a3924c7be190f558
              # TODO: Remove once a release > 2.4.1 is available to us.
              cabal2spec = dontCheck super.cabal2spec;

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

              # Fails in doctests with:
              #     doctests: /nix/store/nda51m9gymbx9qvzmjpfd4393jqq0gdm-ghc-8.6.5/lib/ghc-8.6.5/ghc-prim-0.5.3/HSghc-prim-0.5.3.o: unknown symbol `exp'
              #     doctests: doctests: unable to load package `ghc-prim-0.5.3'
              yesod-paginator = dontCheck super.yesod-paginator;

              # Disabling test suite because it takes extremely long (> 30 minutes):
              # https://github.com/mrkkrp/zip/issues/55
              # TODO: Re-enable when we have version `1.3.1` of it which has the fix.
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

              # Test suite segfaults (perhaps because R's test suite also does?).
              inline-r = dontCheck super.inline-r;

              # TODO For the below packages, it would be better if we could somehow make all users
              # of postgresql-libpq link in openssl via pkgconfig.
              pg-harness-server =
                addStaticLinkerFlagsWithPkgconfig
                  super.pg-harness-server
                  [ final.openssl final.postgresql ]
                  "--libs libpq";
              postgresql-orm =
                addStaticLinkerFlagsWithPkgconfig
                  super.postgresql-orm
                  [ final.openssl final.postgresql ]
                  "--libs libpq";
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

              sdl2-gfx =
                addStaticLinkerFlagsWithPkgconfig
                  super.sdl2-gfx
                  (with final; [
                    nettle
                    SDL2
                    SDL2_gfx

                    libX11
                    libXext
                    libXcursor
                    libXdmcp
                    libXinerama
                    libXi
                    libXrandr
                    libXxf86vm
                    libXScrnSaver
                    libXrender
                    libXfixes
                    libXau
                    libxcb
                    xorg.libpthreadstubs
                  ])
                  "--libs nettle sdl2 SDL2_gfx xcursor";

              sdl2-image =
                addStaticLinkerFlagsWithPkgconfig
                  super.sdl2-image
                  (with final; [
                    nettle
                    SDL2
                    SDL2_image

                    libX11
                    libXext
                    libXcursor
                    libXdmcp
                    libXinerama
                    libXi
                    libXrandr
                    libXxf86vm
                    libXScrnSaver
                    libXrender
                    libXfixes
                    libXau
                    libxcb
                    xorg.libpthreadstubs

                    libjpeg
                    libpng
                    libtiff
                    zlib_both
                    lzma
                    libwebp
                  ])
                  "--libs nettle sdl2 SDL2_image xcursor libpng libjpeg libtiff-4 libwebp";

              # With optimisations disabled, some tests of its test suite don't
              # finish within the 25 seconds timeout.
              skylighting-core =
                (if disableOptimization then dontCheck else lib.id)
                  super.skylighting-core;

              # Test suite loops forever without optimisations..
              text-short =
                (if disableOptimization then dontCheck else lib.id)
                  super.text-short;

              # Flaky QuickCheck test failure:
              #     *** Failed! "00:01": expected Just 00:00:60, found Just 00:01:00 (after 95 tests and 2 shrinks):
              # See https://github.com/haskellari/time-compat/issues/23
              time-compat = dontCheck super.time-compat;

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

              # The test-suite of this package loops forever on 100% CPU (at least on `-O0`).
              bench-show = dontCheck super.bench-show;
              # The test-suite of this package loops forever on 100% CPU (at least on `-O0`).
              # TODO Investigate that because `loop` is nh2's own package.
              loop = dontCheck super.loop;
              # The test-suite of this package loops forever on 100% CPU (at least on `-O0`).
              matrix = dontCheck super.matrix;
              # The test-suite of this package loops forever on 100% CPU (at least on `-O0`).
              # TODO Ask Bas about it
              scientific =
                if integer-simple
                  then dontCheck super.scientific
                  else super.scientific;
              # The test-suite of this package loops forever on 100% CPU (at least on `-O0`).
              x509-validation =
                if integer-simple
                  then dontCheck super.x509-validation
                  else super.x509-validation;

              # Tests depend on util-linux which depends on systemd
              hakyll =
                dontCheck (overrideCabal super.hakyll (drv: {
                  testToolDepends = [];
                }));

              # Inspection tests fail on `disableOptimization`with
              #     examples/Fusion.hs:25:1: sumUpSort `hasNoType` GHC.Types.[] failed expectedly.
              inspection-testing =
                (if disableOptimization then dontCheck else lib.id)
                  super.inspection-testing;

              # Inspection tests fail on `disableOptimization`with
              #     examples/Fusion.hs:25:1: sumUpSort `hasNoType` GHC.Types.[] failed expectedly
              algebraic-graphs =
                (if disableOptimization then dontCheck else lib.id)
                  super.algebraic-graphs;

              # Test suite tries to connect to the Internet
              aur = dontCheck super.aur;

              # Test suite tries to run `minisat` which is not on PATH
              ersatz = dontCheck super.ersatz;

              # doctests test suite fails with:
              #     /build/trifecta-2.1/src/Text/Trifecta/Util/It.hs:61: failure in expression `let keepIt    a = Pure a'
              #     expected:
              #      but got: /nix/store/xz6sgnl68v00yhfk25cfankpdf7g57cs-binutils-2.31.1/bin/ld: warning: type and size of dynamic symbol `TextziTrifectaziDelta_zdfHasDeltaByteString_closure' are not defined
              trifecta = dontCheck super.trifecta;

            });

        });
      };


  pkgsWithHaskellLibsReadyForStaticLinking = pkgsWithArchiveFiles.extend haskellLibsReadyForStaticLinkingOverlay;


  # Overlay all Haskell executables are statically linked.
  staticHaskellBinariesOverlay = final: previous: {
    haskellPackages = previous.haskellPackages.override (old: {
      overrides = final.lib.composeExtensions (old.overrides or (_: _: {})) (self: super:
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
              # `enableShared` seems to be required to avoid `recompile with -fPIC` errors on some packages.
              "--extra-lib-dirs=${final.ncurses.override { enableStatic = true; enableShared = true; }}/lib"
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
          final.lib.mapAttrs
            (name: value:
              if (isProperHaskellPackage value && isExecutable value) then statify value else value
            )
            super
      );
    });
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
        dhall-json
        hsyslog # Small example of handling https://github.com/NixOS/nixpkgs/issues/43849 correctly
        # aura # `aur` maked as broken in nixpkgs, but works here with `allowBroken = true;` actually
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
        # cachix # fails on latest nixpkgs master due to cachix -> nix -> pkgsStatic.busybox dependency, see https://github.com/nh2/static-haskell-nix/pull/61#issuecomment-544331652
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
        "Agda" # fails on `emacs` not building
        "Allure" # depends on `LambdaHack` also in this list
        "csg" # `base >=4.0 && <4.14` on `doctest-driver-gen`
        "cuda" # needs `allowUnfree = true`; enabling it gives `unsupported platform for the pure Linux stdenv`
        "debug" # `regex-base <0.94` on `regex-tdfa-text`
        "diagrams-builder" # `template-haskell >=2.5 && <2.16` on `size-based`
        "gloss-examples" # `base >=4.8 && <4.14` on `repa-io`
        "gtk3" # Haskell package `glib` fails with `Ambiguous module name ‘Gtk2HsSetup’: it was found in multiple packages: gtk2hs-buildtools-0.13.8.0 gtk2hs-buildtools-0.13.8.0`
        "H" # error: anonymous function at pkgs/applications/science/math/R/default.nix:1:1 called with unexpected argument 'javaSupport', at lib/customisation.nix:69:16
        "hamilton" # `_gfortran_concat_string` linker error via openblas
        "hquantlib" # `time >=1.4.0.0 && <1.9.0.0` on `hquantlib-time`
        "ihaskell" # linker error
        "LambdaHack" # fails `systemd` dependency erroring on `#include <printf.h>`
        "language-puppet" # `base >=4.6 && <4.14, ghc-prim >=0.3 && <0.6` for dependency `protolude`
        "learn-physics" # needs opengl: `cannot find -lGLU` `-lGL`
        "odbc" # `odbcss.h: No such file or directory`
        "qchas" # `_gfortran_concat_string` linker error via openblas
        "rhine-gloss" # needs opengl: `cannot find -lGLU` `-lGL`
        "soxlib" # fails `systemd` dependency erroring on `#include <printf.h>`
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
