{ nixpkgs ? import <nixpkgs> { crossSystem = {config="x86_64-unknown-linux-musl";}; }, compiler ? "default" }:

let

  inherit (nixpkgs) pkgs;

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
          # "--ghc-option=-optl=-L${pkgs.gmp6.override { withStatic = true; }}/lib"
          # "--ghc-option=-optl=-L${pkgs.zlib.static}/lib"
          # "--ghc-option=-optl=-L${pkgs.glibc.static}/lib"
          # "--ghc-option=-optl=-L${pkgs.musl}/lib"
        ];
      };

  normalHaskellPackages = if compiler == "default"
                       then pkgs.haskellPackages
                       else pkgs.haskell.packages.${compiler};

  haskellPackages = with pkgs.haskell.lib; normalHaskellPackages.override {
    overrides = self: super: {
      aeson = dontHaddock (dontCheck (super.aeson));
    };
  };

  drv = haskellPackages.callPackage f {};

in

  if pkgs.lib.inNixShell then drv.env else drv
