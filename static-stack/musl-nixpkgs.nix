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

        overrides = self: super: {

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

          # Configure stack to do fully static linking.
          # Also disable library profiling to speed up the build a bit.
          stack = enableCabalFlag (overrideCabal (dontHaddock (disableLibraryProfiling super.stack)) (drv: {
            configureFlags = [
              "--ghc-option=-optl=-static"
              "--extra-lib-dirs=${pkgs.gmp6.override { withStatic = true; }}/lib"
              "--extra-lib-dirs=${pkgs.zlib.static}/lib"
              "--extra-lib-dirs=${pkgs.libiconv.override { enableStatic = true; }}/lib"
            ];
          })) "static";

        };
      };
    };
  };

in musl_nixpkgs # Return the nixpkgs package set, so you can do `nix-build thisfile.nix -A haskellPackages.theDesiredPackage`
