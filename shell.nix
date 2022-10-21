{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  nativeBuildInputs = with pkgs; with haskellPackages; [
    haskell.compiler.ghc8107
    cabal-install
    postgresql
  ];
  buildInputs = with pkgs; [ pkg-config zlib ];
}
