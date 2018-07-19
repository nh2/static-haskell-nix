let
  # validity-overlay = let pkgs = import <nixpkgs> {}; in import (
  #   (pkgs.pkgsMusl.fetchFromGitHub (import /home/niklas/src/haskell/intray/validity-version.nix)
  #   + "/overlay.nix")
  # );

  # TODO: Remove when https://github.com/NixOS/cabal2nix/pull/360 is merged and available
  cabal2nix-fix-overlay = final: previous:
    with final.haskell.lib; {
      haskellPackages = previous.haskellPackages.override (old: {
        overrides = final.lib.composeExtensions (old.overrides or (_: _: {})) (

          self: super: {
            cabal2nix = overrideCabal super.cabal2nix (old: {
              src = pkgs.fetchFromGitHub {
                owner = "nh2";
                repo = "cabal2nix";
                rev = "5721bed2a598a018119413bfe868bd286735cb15";
                sha256 = "1436ri6nlfcgd263byb596dcx6g4l9fx47hm11vfh34x849r2kcy";
              };
            });

          }
        );
      });
    };

  validity-overlay = import /home/niklas/src/haskell/validity/overlay.nix;
  pkgs = (import <nixpkgs> {
    overlays = [ cabal2nix-fix-overlay validity-overlay (import /home/niklas/src/haskell/intray/overlay.nix) ];
    config.allowUnfree = true;
  }).pkgsMusl;

in

# { nixpkgs ? syd-pkgs.pkgsMusl, compiler ? "ghc843" }:
{ compiler ? "ghc843" }:


let

  # pkgs = syd-pkgs.pkgsMusl;
  # pkgs = nixpkgs.pkgsMusl;

  # normalHaskellPackages = builtins.trace ("${pkgs.haskellPackages.intray-server.buildPhase}") pkgs.haskell.packages.${compiler};
  # normalHaskellPackages = pkgs.haskell.packages.${compiler};
  normalHaskellPackages = pkgs.haskellPackages;

  pic = drv: with pkgs.haskell.lib; pkgs.lib.foldl appendConfigureFlag (drv) [
    "--ghc-option=-fPIC"
  ];
  statify = drv: with pkgs.haskell.lib; pkgs.lib.foldl appendConfigureFlag (disableLibraryProfiling (disableSharedExecutables (disableSharedLibraries drv))) [
  # statify = drv: with pkgs.haskell.lib; pkgs.lib.foldl appendConfigureFlag (disableLibraryProfiling (disableSharedExecutables drv)) [
        "--ghc-option=-static"
        "--ghc-option=-optl=-static"
        # "--ghc-option=-fPIC"
        "--extra-lib-dirs=${pkgs.gmp6.override { withStatic = true; }}/lib"
        "--extra-lib-dirs=${pkgs.zlib.static}/lib"
        # XXX: This doesn't actually work "yet":
        # * first, it helps to not remove the static libraries: https://github.com/dtzWill/nixpkgs/commit/54a663a519f622f19424295edb55d01686261bb4 (should be sent upstream)
        # * second, ghc wants to link against libtinfo but no static version of that is built
        #   (actually no shared either, we create symlink for it-- I think)
        "--extra-lib-dirs=${pkgs.ncurses.override { enableStatic = true; }}/lib"
  ];

  # half_statify = drv: with pkgs.haskell.lib; pkgs.lib.foldl appendConfigureFlag (disableLibraryProfiling (disableSharedExecutables (disableSharedLibraries drv))) [

  # Using .out because "sqlite" is the package that contains only the sqlite3 binary, not the library.
  sqlite_static = (pkgs.sqlite.overrideAttrs (old: { dontDisableStatic = true; })).out;
  sqlite_static_full = pkgs.sqlite.overrideAttrs (old: { dontDisableStatic = true; });

  # useSqliteWithStaticSupport = drv: with pkgs.haskell.lib; appendConfigureFlag drv [
  #   "--extra-lib-dirs=${sqlite_static}/lib"
  # ];

  linkSqliteStatically = drv: with pkgs.haskell.lib; appendConfigureFlag drv [
    "--extra-lib-dirs=${sqlite_static}/lib"
    # TODO: Not great, instead of this we should make sure that
    # persistent-sqlite actually depends on the static version
    "--ghc-option=-optl=-l:libsqlite3.a"
  ];



  haskellPackages = with pkgs.haskell.lib; normalHaskellPackages.override (old: {
    overrides = pkgs.lib.composeExtensions (old.overrides or (_: _: {})) (self: super:
    let
      # Cabal_dedupe_src = pkgs.fetchFromGitHub {
      #   owner = "nh2";
      #   repo = "cabal";
      #   rev = "7cb409fe7433833a3a8aa4b38a5fb3c2e01a5e5d";
      #   sha256 = "0qhq80mfm55fbnzk8p6ar13b954wwd2y9c9pxlsh6rmaa91rd6y0";
      # };
      Cabal_dedupe_src =
        let
          filter = name: type:
            let baseName = baseNameOf (toString name); in
            !( (type == "directory" && baseName == ".stack-work") );
        in pkgs.lib.cleanSourceWith { inherit filter; src = /home/niklas/src/haskell/cabal; };

      Cabal_dedupe_subdir = pkgs.stdenv.mkDerivation {
        name = "cabal-dedupe-src";
        buildCommand = ''
          cp -rv ${Cabal_dedupe_src}/Cabal/ $out
        '';
      };

      Cabal_dedupe = self.callCabal2nix "Cabal" Cabal_dedupe_subdir {};

      useFixedCabal = drv: overrideCabal drv (old: {
        libraryHaskellDepends = old.libraryHaskellDepends ++ [ Cabal_dedupe ];
        setupHaskellDepends = [ Cabal_dedupe ];
      });

      proper_statify = drv: with pkgs.haskell.lib; pkgs.lib.foldl appendConfigureFlag (disableLibraryProfiling (disableSharedExecutables (useFixedCabal drv))) [
            # "--ghc-option=-fPIC"
            "--enable-executable-static" # requires `useFixedCabal`
            "--extra-lib-dirs=${pkgs.gmp6.override { withStatic = true; }}/lib"
            "--extra-lib-dirs=${pkgs.zlib.static}/lib"
            # XXX: This doesn't actually work "yet":
            # * first, it helps to not remove the static libraries: https://github.com/dtzWill/nixpkgs/commit/54a663a519f622f19424295edb55d01686261bb4 (should be sent upstream)
            # * second, ghc wants to link against libtinfo but no static version of that is built
            #   (actually no shared either, we create symlink for it-- I think)
            "--extra-lib-dirs=${pkgs.ncurses.override { enableStatic = true; }}/lib"
      ];

    in
    {
  # haskellPackages = with pkgs.haskell.lib; normalHaskellPackages.extend (self: super: {
    # Helpers for other packages

      hpc-coveralls = appendPatch super.hpc-coveralls (builtins.fetchurl https://github.com/guillaume-nargeot/hpc-coveralls/pull/73/commits/344217f513b7adfb9037f73026f5d928be98d07f.patch);
      # TODO: This doesn't seem to be picked up by our overlays, they seem to use non-static sqlite
      # persistent-sqlite = builtins.trace "here" useSqliteWithStaticSupport (super.persistent-sqlite.override { sqlite = sqlite_static_full; });
      persistent-sqlite = super.persistent-sqlite.override { sqlite = sqlite_static_full; };

      # Static executables that work

      hello = statify super.hello;
      hlint = statify super.hlint;
      ShellCheck = statify super.ShellCheck;
      cabal-install = statify super.cabal-install;
      bench = statify super.bench;

      # intray-server = linkSqliteStatically (statify super.intray-server);
      # intray-web-server = linkSqliteStatically (statify super.intray-web-server);
      # intray-server = useFixedCabal super.intray-server;
      intray-server = super.intray-server;
      # intray-server-test-utils = useFixedCabal super.intray-server-test-utils;
      intray-server-test-utils = super.intray-server-test-utils;
      # intray-web-server = useFixedCabal (linkSqliteStatically (statify super.intray-web-server));
      # intray-web-server = statify super.intray-web-server;
      intray-web-server = proper_statify super.intray-web-server;

      # Static executables that don't work yet

      # stack = appendConfigureFlag (statify super.stack) [ "--ghc-option=-j1" ];
      # stack = overrideCabal (appendConfigureFlag (half_statify super.stack) [ "--ghc-option=-j1" ]) (old: {
      #   src = /home/niklas/src/haskell/stack-small;
      # });
      # If we `useFixedCabal` on stack, we also need to use the
      # it on hpack and hackage-security because otherwise
      # stack depends on 2 different versions of Cabal.
      hpack = useFixedCabal super.hpack;
      hackage-security = useFixedCabal super.hackage-security;
      # stack = useFixedCabal (half_statify super.stack);
      stack = proper_statify super.stack;
      cachix = statify super.cachix;
      dhall = statify super.dhall;
    });
  });

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
    inherit sqlite_static;
  }

# TODO Update README to ensure mention that I use nixpkgs 762dc9d (which has some patches picked)
