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

  statify = drv: with pkgs.haskell.lib; pkgs.lib.foldl appendConfigureFlag (justStaticExecutables drv) [
        "--ghc-option=-optl=-static"
        "--extra-lib-dirs=${pkgs.gmp6.override { withStatic = true; }}/lib"
        "--extra-lib-dirs=${pkgs.zlib.static}/lib"
  ];

  haskellPackages = with pkgs.haskell.lib; normalHaskellPackages.override {
    overrides = self: super: {
      hpc-coveralls = appendPatch super.hpc-coveralls (builtins.fetchurl https://github.com/guillaume-nargeot/hpc-coveralls/pull/73/commits/344217f513b7adfb9037f73026f5d928be98d07f.patch);

      cachix = statify super.cachix;
      blank-me-up = super.callPackage f {}; # XXX ?!
      hello = statify super.hello;

      stack = statify super.stack;
      hlint = statify super.hlint;
      dhall = statify super.dhall;
      ShellCheck = statify super.ShellCheck;
      bench = statify super.bench;
      cabal-install = statify super.cabal-install;

    };
  };

  #drv = haskellPackages.callPackage f {};

in
  {
    inherit (haskellPackages) cachix hpc-coveralls hello blank-me-up stack hlint dhall ShellCheck bench cabal-install;
  }
  #if pkgs.lib.inNixShell then drv.env else drv
