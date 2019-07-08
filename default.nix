# Note: This is just a minimal example. For proper usage, see the README.

{ nixpkgs ? (import <nixpkgs> {}).pkgsMusl, compiler ? "ghc864", strip ? true }:


let

  pkgs = nixpkgs.pkgsMusl;

  example-scotty-app = { mkDerivation, base, scotty, stdenv }:
      mkDerivation {
        pname = "example-scotty-app";
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
          "--extra-lib-dirs=${pkgs.libffi.overrideAttrs (old: { dontDisableStatic = true; })}/lib"
        ] ++ pkgs.lib.optionals (!strip) [
          "--disable-executable-stripping"
        ] ;
      };

  normalHaskellPackages = pkgs.haskell.packages.${compiler};

  haskellPackages = with pkgs.haskell.lib; normalHaskellPackages.override {
    overrides = self: super: {
      # Dependencies we need to patch
      hpc-coveralls = appendPatch super.hpc-coveralls (builtins.fetchurl https://github.com/guillaume-nargeot/hpc-coveralls/pull/73/commits/344217f513b7adfb9037f73026f5d928be98d07f.patch);
    };
  };

  drv = haskellPackages.callPackage example-scotty-app {};

in
  if pkgs.lib.inNixShell then drv.env else drv
