{ nixpkgs ? import <nixpkgs> {}, compiler ? "ghc843" }:


let

  pkgs = nixpkgs.pkgsMusl;


  f = { mkDerivation, base, scotty, stdenv }:
      mkDerivation {
        pname = "blank-me-up";
        version = "0.1.0.0";
        src = pkgs.lib.sourceByRegex ./. [
          ".*\.cabal$"
          "^Setup.hs$"
          "^Main.hs$"
        ];
        isLibrary = false;
        isExecutable = true;
        enableSharedExecutables = false;
        enableSharedLibraries = false;
        executableHaskellDepends = [ base scotty ];
        license = stdenv.lib.licenses.bsd3;
        configureFlags = [
          "--ghc-option=-optl=-static"
          "--extra-lib-dirs=${pkgs.gmp6.override { withStatic = true; }}/lib"
          "--extra-lib-dirs=${pkgs.zlib.static}/lib"
        ];
      };

  normalHaskellPackages = pkgs.haskell.packages.${compiler};

  haskellPackages = with pkgs.haskell.lib; normalHaskellPackages.override {
    overrides = self: super: {
      # Without this, we get an error when haddock is executed on aeson:
      #   <command line>: can't load .so/.DLL for: libgmp.so (libgmp.so: cannot open shared object file: No such file or directory)
      #   builder for '/nix/store/3x9abjx43jn2fg4h5av2vk0igmwv67xs-aeson-1.2.4.0-x86_64-unknown-linux-musl.drv' failed with exit code 1
      # Note sure yet why it's trying to use libgmp.so when executing haddock.
      aeson = dontHaddock super.aeson;

      hpc-coveralls = appendPatch super.hpc-coveralls (builtins.fetchurl https://github.com/guillaume-nargeot/hpc-coveralls/pull/73/commits/344217f513b7adfb9037f73026f5d928be98d07f.patch);
    };
  };

  drv = haskellPackages.callPackage f {};

in

  if pkgs.lib.inNixShell then drv.env else drv
