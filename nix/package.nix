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
  jq,
  procps,
  which,
  xdg-user-dirs,
  shared-mime-info,
}: let
  runtimeDeps = [
    coreutils
    dbus
    file
    gawk
    glib.bin
    gnugrep
    gnused
    hostname
    jq
    nushell
    procps
    which
    xdg-user-dirs
    shared-mime-info
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
          --prefix PATH ":" ${lib.makeBinPath runtimeDeps}
      done

      runHook postInstall
    '';

    meta = {
      homepage = "https://www.freedesktop.org/wiki/Software/xdg-utils/";
      description = "Set of command line tools that assist applications with a variety of desktop integration tasks";
      license = lib.licenses.mit;
      maintainers = [];
      platforms = lib.platforms.all;
    };
  }
