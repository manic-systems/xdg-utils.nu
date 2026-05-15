{
  inputs.nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";

  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    inherit (nixpkgs) lib;
    forAllSystems = lib.genAttrs lib.platforms.linux;
  in {
    overlays = {
      default = final: _: let
        mk = coreutils: final.callPackage ./nix/package.nix {inherit coreutils;};
      in {
        xdg-utils-nu = mk final.coreutils;
        xdg-utils-nu-uutils = mk final.uutils-coreutils-noprefix;
      };
    };

    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system}.extend self.overlays.default;
    in {
      inherit (pkgs) xdg-utils-nu xdg-utils-nu-uutils;
      default = pkgs.xdg-utils-nu;
    });
  };
}
