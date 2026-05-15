{
  inputs.nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";

  outputs = {nixpkgs, ...}: let
    forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.platforms.linux;
  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      mk = coreutils: pkgs.callPackage ./nix/package.nix {inherit coreutils;};
    in {
      default = mk pkgs.coreutils;
      uutils = mk pkgs.uutils-coreutils-noprefix;
    });
  };
}
