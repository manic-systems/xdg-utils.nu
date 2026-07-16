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

    devShells = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.mkShell {
        name = "xdg-utils-nu";

        strictDeps = true;
        nativeBuildInputs = [
          pkgs.pkg-config
          pkgs.nufmt
          (pkgs.writers.writeNuBin "nucheck" /* nu */ ''
            glob $"($env.out)/bin/.xdg-*-wrapped"
            | each {|wrapped|
                let diags = (
                  nu --ide-check 100 $wrapped
                    | lines
                    | each {|l| try { $l | from json } catch { null } }
                    | where {|d| $d != null and $d.type == "diagnostic" }
                )
                if not ($diags | is-empty) {
                  print --stderr $"Parse errors in ($wrapped):"
                  $diags | each {|d| print --stderr ($d | to json --raw) }
                  exit 1
                }
              }
            | ignore
          '')
        ];
        buildInputs = [pkgs.dbus];
      };
    });
  };
}
