{
  lib,
  stdenvNoCC,
  nushell,
  makeWrapper,
  coreutils,
  dbus,
  file,
  gawk,
  glib,
  gnugrep,
  gnused,
  hostname,
  perlPackages,
  procps,
  which,
  xdg-user-dirs,
  shared-mime-info,
  xprop,
  xset,
}: let
  perl-with-deps = perlPackages.perl.withPackages (p: [p.NetDBus p.X11Protocol]);
  runtimeDeps = [
    coreutils
    dbus
    file
    gawk
    glib.bin
    gnugrep
    gnused
    hostname
    nushell
    perl-with-deps
    procps
    which
    xdg-user-dirs
    shared-mime-info
    xprop
    xset
  ];
in
  stdenvNoCC.mkDerivation {
    pname = "xdg-utils";
    version = "1.2.1";

    src = let
      fs = lib.fileset;
      s = ../.;
    in
      fs.toSource {
        root = s;
        fileset = fs.unions [
          (fs.fileFilter (file: builtins.any file.hasExt ["nu"]) (s + /scripts))
        ];
      };

    nativeBuildInputs = [makeWrapper];

    doInstallCheck = true;
    installCheckInputs = [nushell];
    installCheckPhase = ''
      runHook preInstallCheck

      nu --no-config-file --commands '
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
      '

      runHook postInstallCheck
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin

      # Install Nushell scripts to bin, stripping .nu extension
      for f in scripts/xdg-*.nu; do
        base=$(basename "$f" .nu)
        # Keep .nu extension on the common module for `use` resolution
        if [ "$base" = "xdg-utils-common" ]; then
          cp "$f" "$out/bin/xdg-utils-common.nu"
        else
          cp "$f" "$out/bin/$base"
        fi
      done

      # Wrap all xdg scripts with runtime PATH
      for f in $out/bin/xdg-*; do
        # Skip the common module (it's not an entry point)
        [ "$(basename "$f")" = "xdg-utils-common.nu" ] && continue
        chmod +x "$f"
        wrapProgram "$f" \
          --prefix PATH ":" "$out/bin:${lib.makeBinPath runtimeDeps}"
      done

      runHook postInstall
    '';

    meta = {
      homepage = "https://www.freedesktop.org/wiki/Software/xdg-utils/";
      description = "Set of command line tools that assist applications with a variety of desktop integration tasks";
      license = lib.licenses.mit;
      maintainers = [];
      platforms = lib.platforms.linux;
    };
  }
