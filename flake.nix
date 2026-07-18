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
        workspaceSrc = lib.fileset.toSource {
          root = ./plugins;
          fileset = lib.fileset.unions [
            ./plugins/Cargo.toml
            ./plugins/Cargo.lock
            ./plugins/xdg-core
            ./plugins/nu_plugin_xdg
            ./plugins/nu_plugin_dbus
          ];
        };
        nu_plugin_dbus = final.rustPlatform.buildRustPackage {
          pname = "nu_plugin_dbus";
          version = "0.1.0";
          src = workspaceSrc;
          cargoLock.lockFile = ./plugins/Cargo.lock;
          cargoBuildFlags = ["-p" "nu_plugin_dbus"];
          cargoTestFlags = ["-p" "nu_plugin_dbus"];
          nativeBuildInputs = [final.pkg-config];
          buildInputs = [final.dbus];
          meta.mainProgram = "nu_plugin_dbus";
        };
        nu_plugin_xdg = final.rustPlatform.buildRustPackage {
          pname = "nu_plugin_xdg";
          version = "0.1.0";
          src = workspaceSrc;
          cargoLock.lockFile = ./plugins/Cargo.lock;
          cargoBuildFlags = ["-p" "nu_plugin_xdg"];
          cargoTestFlags = ["-p" "nu_plugin_xdg" "-p" "xdg-core"];
          meta.mainProgram = "nu_plugin_xdg";
        };
        mk = coreutils:
          final.callPackage ./nix/package.nix {
            inherit coreutils nu_plugin_dbus nu_plugin_xdg;
          };
      in {
        inherit nu_plugin_dbus nu_plugin_xdg;
        xdg-utils-nu = mk final.coreutils;
        xdg-utils-nu-uutils = mk final.uutils-coreutils-noprefix;
      };
    };

    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system}.extend self.overlays.default;
    in {
      inherit (pkgs) xdg-utils-nu xdg-utils-nu-uutils nu_plugin_dbus nu_plugin_xdg;
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
