let
  normal_nixpkgs = import (fetchTarball https://github.com/NixOS/nixpkgs-channels/archive/a0b977bdb461a756047adb1dcbb70d7c106507da.tar.gz) {};

  musl_nixpkgs = import (fetchTarball https://github.com/dtzWill/nixpkgs/archive/7048fc71e325c69ddfa62309c0b661b430774eac.tar.gz) {
    crossSystem = { config = "x86_64-unknown-linux-musl"; };

    config.packageOverrides = pkgs: rec {

      haskell = pkgs.haskell // {
        packages = pkgs.haskell.packages // {
          ghc822 = pkgs.haskell.packages.ghc822.extend (self: super: {
            # Patch out the override
            #   jailbreak-cabal = pkgs.haskell.packages.ghc802.jailbreak-cabal;
            # (see https://github.com/dtzWill/nixpkgs/blob/7048fc71e325c69ddfa62309c0b661b430774eac/pkgs/development/haskell-modules/configuration-ghc-8.2.x.nix#L47-L48)
            # to avoid building an entire whole new ghc802 just for the purpose of building `jailbreak-cabal`.
            # The build of that ghc802's Python dependencies even fails at the time of writing with
            # this error: https://github.com/pyca/pyopenssl/issues/768
            #
            # Doing this is basically picking this change:
            #   https://github.com/NixOS/nixpkgs/commit/85c5e8d65165fe414a6904b84c4c233f5f46bdbc
            #
            # The problematic dependency chain without this is (obtained with `nix-store -q --tree thestack.drv`):
            #
            #   /nix/store/32wx43x02w0wdjdyync9lxy5z0kvxn1z-stack-1.6.5-x86_64-unknown-linux-musl.drv
            #   +---/nix/store/azy0x292d9as6m6zpkb530y7ddq58j5x-network-uri-2.6.1.0-x86_64-unknown-linux-musl.drv
            #   |   +---/nix/store/q1fbbzapdklkxj9nfflak7mg46ph943q-parsec-3.1.13.0-x86_64-unknown-linux-musl.drv
            #   |   |   +---/nix/store/hlvhdbziblfgdj6vr3xcjwf5x34x6sl8-jailbreak-cabal-1.3.3.drv
            #   |   |   |   +---/nix/store/0py7dc4aqfvxbs8vgk93g8sq245n1pip-ghc-8.0.2.drv
            #   |   |   |   |   +---/nix/store/02rxqgk0m859dyxqbi7jnfcrxqh4g3jc-python2.7-Sphinx-1.7.1.drv
            #   |   |   |   |   |   +---/nix/store/srnda8crn5sn2qvhxxxakhwvq6nwlxx4-python2.7-requests-2.18.4.drv
            #   |   |   |   |   |   |   +---/nix/store/1fdqh8calbv97mq6x0s3vd6dj8np1zcb-python2.7-urllib3-1.22.drv
            #   |   |   |   |   |   |   |   +---/nix/store/algwr7rgks04c288hhjk3kxw9m2dv6az-python2.7-pyOpenSSL-17.5.0.drv
            #
            # This can be removed once we're on a nixpkgs commit that has the above-mentioned change merged.
            jailbreak-cabal = normal_nixpkgs.haskell.packages.ghc822.jailbreak-cabal;
          });
        };
      };

      # TODO Cleanup: Right now I can't tell if `.override` or `.extend` is better,
      #      see https://github.com/NixOS/nixpkgs/issues/26561#issuecomment-397331519.
      haskellPackages = with pkgs.haskell.lib; pkgs.haskell.packages.ghc822.override {

        overrides = self: super: rec {

          # Fixes error
          #   System/Clock.hsc:44 directive let cannot be handled in cross-compilation mode
          clock = overrideCabal super.clock (old: {
            src = normal_nixpkgs.fetchgit {
              url = "https://github.com/corsis/clock.git";
              rev = "00435ddf926b3603a3576d98e44763d165d2ec2c";
              sha256 = "0z46s7874a53j1prdrynvca5gzhh6clf9dj7c5g8xngvhmmjz2wa";
            };
          });

          # Without this, we get an error when haddock is executed on these select packages:
          #   <command line>: can't load .so/.DLL for: libgmp.so (libgmp.so: cannot open shared object file: No such file or directory)
          # Note sure yet why it's trying to use libgmp.so when executing haddock.
          optparse-applicative = dontHaddock super.optparse-applicative;
          th-lift-instances = dontHaddock super.th-lift-instances;
          th-orphans = dontHaddock super.th-orphans;
          store = dontHaddock super.store;
          persistent-sqlite = dontHaddock super.persistent-sqlite;
          aeson = dontHaddock super.aeson;

          # A couple of dependencies that this version of stack needs that aren't at this version in nixpkgs
          # (copied simply from nixpkgs master):

          "rio" = super.callPackage
            ({ mkDerivation, base, bytestring, containers, deepseq, directory
             , exceptions, filepath, hashable, hspec, microlens, mtl, primitive
             , process, text, time, typed-process, unix, unliftio
             , unordered-containers, vector
             }:
             mkDerivation {
               pname = "rio";
               version = "0.1.2.0";
               sha256 = "0449jjgw38dwf0lw3vq0ri3gh7mlzfjkajz8xdvxr76ffs9kncwq";
               libraryHaskellDepends = [
                 base bytestring containers deepseq directory exceptions filepath
                 hashable microlens mtl primitive process text time typed-process
                 unix unliftio unordered-containers vector
               ];
               testHaskellDepends = [
                 base bytestring containers deepseq directory exceptions filepath
                 hashable hspec microlens mtl primitive process text time
                 typed-process unix unliftio unordered-containers vector
               ];
               description = "A standard library for Haskell";
               license = pkgs.stdenv.lib.licenses.mit;
             }) {};

          "unliftio" = super.callPackage
            ({ mkDerivation, async, base, deepseq, directory, filepath, hspec
             , process, stm, time, transformers, unix, unliftio-core
             }:
             mkDerivation {
               pname = "unliftio";
               version = "0.2.7.0";
               sha256 = "0qql93lq5w7qghl454cc3s1i8v1jb4h08n82fqkw0kli4g3g9njs";
               libraryHaskellDepends = [
                 async base deepseq directory filepath process stm time transformers
                 unix unliftio-core
               ];
               testHaskellDepends = [
                 async base deepseq directory filepath hspec process stm time
                 transformers unix unliftio-core
               ];
               description = "The MonadUnliftIO typeclass for unlifting monads to IO (batteries included)";
               license = pkgs.stdenv.lib.licenses.mit;
             }) {};

          "typed-process" = super.callPackage
            ({ mkDerivation, async, base, base64-bytestring, bytestring, hspec
             , process, stm, temporary, transformers
             }:
             mkDerivation {
               pname = "typed-process";
               version = "0.2.2.0";
               sha256 = "0c6gvgvjyncbni9a5bvpbglknd4yclr3d3hfg9bhgahmkj40dva2";
               libraryHaskellDepends = [
                 async base bytestring process stm transformers
               ];
               testHaskellDepends = [
                 async base base64-bytestring bytestring hspec process stm temporary
                 transformers
               ];
               description = "Run external processes, with strong typing of streams";
               license = pkgs.stdenv.lib.licenses.mit;
             }) {};

          "mustache" = dontHaddock (super.callPackage
            ({ mkDerivation, aeson, base, base-unicode-symbols, bytestring
             , cmdargs, containers, directory, either, filepath, hspec, lens
             , mtl, parsec, process, scientific, tar, template-haskell
             , temporary, text, th-lift, unordered-containers, vector, wreq
             , yaml, zlib
             }:
             mkDerivation {
               pname = "mustache";
               version = "2.3.0";
               sha256 = "1q3vadcvv2pxg6rpp92jq5zy784jxphdfpf6xn9y6wg9g3jn7201";
               isLibrary = true;
               isExecutable = true;
               libraryHaskellDepends = [
                 aeson base bytestring containers directory either filepath mtl
                 parsec scientific template-haskell text th-lift
                 unordered-containers vector
               ];
               executableHaskellDepends = [
                 aeson base bytestring cmdargs filepath text yaml
               ];
               testHaskellDepends = [
                 aeson base base-unicode-symbols bytestring directory filepath hspec
                 lens process tar temporary text unordered-containers wreq yaml zlib
               ];
               description = "A mustache template parser library";
               license = pkgs.stdenv.lib.licenses.bsd3;
             }) {});

          "Cabal_2_2_0_1" = dontHaddock (super.callPackage
            ({ mkDerivation, array, base, base-compat, base-orphans, binary
             , bytestring, containers, deepseq, Diff, directory, filepath
             , integer-logarithms, mtl, optparse-applicative, parsec, pretty
             , process, QuickCheck, tagged, tar, tasty, tasty-golden
             , tasty-hunit, tasty-quickcheck, text, time, transformers
             , tree-diff, unix
             }:
             mkDerivation {
               pname = "Cabal";
               version = "2.2.0.1";
               sha256 = "0yqa6fm9jvr0ka6b1mf17bf43092dc1bai6mqyiwwwyz0h9k1d82";
               libraryHaskellDepends = [
                 array base binary bytestring containers deepseq directory filepath
                 mtl parsec pretty process text time transformers unix
               ];
               testHaskellDepends = [
                 array base base-compat base-orphans bytestring containers deepseq
                 Diff directory filepath integer-logarithms optparse-applicative
                 pretty process QuickCheck tagged tar tasty tasty-golden tasty-hunit
                 tasty-quickcheck text tree-diff
               ];
               doCheck = false;
               description = "A framework for packaging Haskell software";
               license = pkgs.stdenv.lib.licenses.bsd3;
               hydraPlatforms = pkgs.stdenv.lib.platforms.none;
             }) {});


          "hpack" = dontHaddock (super.callPackage
            ({ mkDerivation, aeson, base, bifunctors, bytestring
             , containers, cryptonite, deepseq, directory, filepath, Glob, hspec
             , http-client, http-client-tls, http-types, HUnit, interpolate
             , mockery, pretty, QuickCheck, scientific, template-haskell
             , temporary, text, transformers, unordered-containers, vector, yaml
             }:
             mkDerivation {
               pname = "hpack";
               version = "0.27.0";
               sha256 = "1vrbf2b5bin9sdm80bj0jkcwc2d9zh29jh4qjhfvcpk4ggbl8iym";
               isLibrary = true;
               isExecutable = true;
               libraryHaskellDepends = [
                 aeson base bifunctors bytestring Cabal_2_2_0_1 containers cryptonite
                 deepseq directory filepath Glob http-client http-client-tls
                 http-types pretty scientific text transformers unordered-containers
                 vector yaml
               ];
               executableHaskellDepends = [
                 aeson base bifunctors bytestring Cabal_2_2_0_1 containers cryptonite
                 deepseq directory filepath Glob http-client http-client-tls
                 http-types pretty scientific text transformers unordered-containers
                 vector yaml
               ];
               testHaskellDepends = [
                 aeson base bifunctors bytestring Cabal_2_2_0_1 containers cryptonite
                 deepseq directory filepath Glob hspec http-client http-client-tls
                 http-types HUnit interpolate mockery pretty QuickCheck scientific
                 template-haskell temporary text transformers unordered-containers
                 vector yaml
               ];
               description = "An alternative format for Haskell packages";
               license = pkgs.stdenv.lib.licenses.mit;
             }) {});

          "hackage-security" = dontHaddock (super.callPackage
            ({ mkDerivation, base, base16-bytestring, base64-bytestring
             , bytestring, containers, cryptohash-sha256, directory
             , ed25519, filepath, ghc-prim, mtl, network, network-uri, parsec
             , pretty, QuickCheck, tar, tasty, tasty-hunit, tasty-quickcheck
             , template-haskell, temporary, time, transformers, zlib
             }:
             mkDerivation {
               pname = "hackage-security";
               version = "0.5.3.0";
               sha256 = "08bwawc7ramgdh54vcly2m9pvfchp0ahhs8117jajni6x4bnx66v";
               libraryHaskellDepends = [
                 base base16-bytestring base64-bytestring bytestring Cabal_2_2_0_1
                 containers cryptohash-sha256 directory ed25519 filepath ghc-prim
                 mtl network network-uri parsec pretty tar template-haskell time
                 transformers zlib
               ];
               testHaskellDepends = [
                 base bytestring Cabal_2_2_0_1 containers network-uri QuickCheck tar tasty
                 tasty-hunit tasty-quickcheck temporary time zlib
               ];
               description = "Hackage security library";
               license = pkgs.stdenv.lib.licenses.bsd3;
             }) {});

          # Configure stack to do fully static linking.
          # Also disable library profiling to speed up the build a bit.
          stack = enableCabalFlag (overrideCabal (dontHaddock (disableLibraryProfiling super.stack)) (drv:
            let
              version = "1.7.1";
            in
            {
              src = pkgs.fetchFromGitHub {
                owner = "commercialhaskell";
                repo = "stack";
                rev = "v${version}";
                sha256 = "176gr5xwc8r628wci4qg034jvgrgfzzw9yss87k30838fp73ms31";
              };
              version = version;
              revision = "4";
              editedCabalFile = "06imaj3adll2lwfivkv3axzfkaj6nfp0vbq6vsmpknw0r8s32xad";
              libraryHaskellDepends = drv.libraryHaskellDepends ++ [
                self.rio
                self.mustache
                self.Cabal_2_2_0_1
              ];
              executableHaskellDepends = drv.executableHaskellDepends ++ [
                self.rio
                self.mustache
                self.Cabal_2_2_0_1
              ];
              testHaskellDepends = drv.testHaskellDepends ++ [
                self.rio
                self.mustache
                self.Cabal_2_2_0_1
              ];
              configureFlags = [
                "--ghc-option=-optl=-static"
                "--extra-lib-dirs=${pkgs.gmp6.override { withStatic = true; }}/lib"
                "--extra-lib-dirs=${pkgs.zlib.static}/lib"
                "--extra-lib-dirs=${pkgs.libiconv.override { enableStatic = true; }}/lib"
              ];
            }
          )) "static";

        };
      };
    };
  };

in musl_nixpkgs # Return the nixpkgs package set, so you can do `nix-build thisfile.nix -A haskellPackages.theDesiredPackage`
