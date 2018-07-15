{ nixpkgs ? (import <nixpkgs> {}).pkgsMusl, compiler ? "ghc843" }:


let

  pkgs = nixpkgs.pkgsMusl;

  normalHaskellPackages = pkgs.haskell.packages.${compiler};

  statify = drv: with pkgs.haskell.lib; pkgs.lib.foldl appendConfigureFlag (disableLibraryProfiling (disableSharedExecutables (disableSharedLibraries drv))) [
        "--ghc-option=-static"
        "--ghc-option=-optl=-static"
        "--ghc-option=-fPIC"
        "--extra-lib-dirs=${pkgs.gmp6.override { withStatic = true; }}/lib"
        "--extra-lib-dirs=${pkgs.zlib.static}/lib"
        # XXX: This doesn't actually work "yet":
        # * first, it helps to not remove the static libraries: https://github.com/dtzWill/nixpkgs/commit/54a663a519f622f19424295edb55d01686261bb4 (should be sent upstream)
        # * second, ghc wants to link against libtinfo but no static version of that is built
        #   (actually no shared either, we create symlink for it-- I think)
        "--extra-lib-dirs=${pkgs.ncurses.override { enableStatic = true; }}/lib"
  ];

  haskellPackages = with pkgs.haskell.lib; normalHaskellPackages.override {
    overrides = self: super: {
      # Helpers for other packages

      hpc-coveralls = appendPatch super.hpc-coveralls (builtins.fetchurl https://github.com/guillaume-nargeot/hpc-coveralls/pull/73/commits/344217f513b7adfb9037f73026f5d928be98d07f.patch);

      # Static executables that work

      hello = statify super.hello;
      hlint = statify super.hlint;
      ShellCheck = statify super.ShellCheck;
      cabal-install = statify super.cabal-install;
      bench = statify super.bench;

      # Static executables that don't work yet

      stack = appendConfigureFlag (statify super.stack) [ "--ghc-option=-j1" ];
      cachix = statify super.cachix;
      dhall = statify super.dhall;
    };
  };

in
  rec {
    working = {
      inherit (haskellPackages)
        hello
        hlint
        ShellCheck
        cabal-install
        bench
        ;
    };

    notWorking = {
      inherit (haskellPackages)
        stack
        dhall
        cachix
        ;
    };

    all = working // notWorking;

    inherit haskellPackages;
  }
