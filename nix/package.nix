{
  lib,
  stdenvNoCC,
  nushell,
  makeWrapper,
  coreutils,
  glib,
  nu_plugin_dbus,
  nu_plugin_xdg,
}: let
  runtimeDeps = [
    coreutils
    glib.bin
    nushell
  ];

  # Plugins are loaded via a build-time registry so that the wrapped
  # scripts can call `dbus ...` / `xdg ...` directly.
  plugins = [
    "${nu_plugin_dbus}/bin/nu_plugin_dbus"
    "${nu_plugin_xdg}/bin/nu_plugin_xdg"
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

    nativeBuildInputs = [makeWrapper nushell];

    doInstallCheck = true;
    installCheckInputs = [nushell];
    installCheckPhase = ''
      runHook preInstallCheck

      # Parse-check every installed script with the plugin registry loaded
      nu --plugin-config $out/share/nu-plugins/registry.msgpackz --commands '
        glob $"($env.out)/libexec/xdg-utils-nu/xdg-*"
          | where {|s| ($s | path basename) != "xdg-utils-common.nu" }
          | each {|script|
              let diags = (
                nu --plugin-config $"($env.out)/share/nu-plugins/registry.msgpackz" --ide-check 100 $script
                  | lines
                  | each {|l| try { $l | from json } catch { null } }
                  | where {|d| $d != null and $d.type == "diagnostic" }
              )
              if not ($diags | is-empty) {
                print --stderr $"Parse errors in ($script):"
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

      mkdir -p $out/bin $out/libexec/xdg-utils-nu $out/share/nu-plugins

      # Install Nushell scripts to libexec.
      for f in scripts/xdg-*.nu; do
        base=$(basename "$f" .nu)
        # Keep .nu extension on the common module for `use` resolution.
        if [ "$base" = "xdg-utils-common" ]; then
          cp "$f" "$out/libexec/xdg-utils-nu/xdg-utils-common.nu"
        else
          cp "$f" "$out/libexec/xdg-utils-nu/$base"
        fi
      done

      # Build a plugin registry pointing at the nix-store plugin binaries.
      export HOME=$TMPDIR
      reg=$out/share/nu-plugins/registry.msgpackz
      for plugin in ${lib.escapeShellArgs plugins}; do
        nu --plugin-config "$reg" --commands "plugin add $plugin"
      done

      # Keep uncompressed plugin store references in each wrapper since Nix cannot
      # discover them inside the compressed registry when computing the closure.
      pluginPath="${lib.makeBinPath [nu_plugin_dbus nu_plugin_xdg]}"
      for f in $out/libexec/xdg-utils-nu/xdg-*; do
        base=$(basename "$f")
        [ "$base" = "xdg-utils-common.nu" ] && continue
        makeWrapper ${nushell}/bin/nu "$out/bin/$base" \
          --add-flags "--plugin-config $reg" \
          --add-flags "$f" \
          --prefix PATH ":" "$out/bin:${lib.makeBinPath runtimeDeps}:$pluginPath"
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
