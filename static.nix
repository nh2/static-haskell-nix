let
  pkgs = import <nixpkgs> {};
in pkgs.buildFHSUserEnv {
  name = "fhs";
  targetPkgs = pkgs: [
    (pkgs.haskellPackages.ghcWithPackages (p: with p; [ cabal-install ]))
    pkgs.gmp5.static
    pkgs.glibc.static
    pkgs.zlib.static
    pkgs.zlib.dev
  ];
}
