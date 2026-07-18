#!/usr/bin/env nu
# xdg-open - Open a URL in the registered default application
$env.XDG_UTILS_ENABLE_DOUBLE_HYPEN = "y"
# Load common functions
use xdg-utils-common.nu *
# Check if string is a URL scheme
def has_url_scheme [text: string] { $text =~ '^[[:alpha:]][[:alpha:][:digit:]+.\-]*:' }
# Check if argument is a file:// URL or path
def is_file_url_or_path [url_or_path: string] { ($url_or_path | str starts-with "file://") or not (has_url_scheme $url_or_path) }
# Get the local hostname.
def get_hostname []: nothing -> string {
    sys host | get hostname
}
# Convert file:// URL to path
def --env file_url_to_path [file: string] {
    if ($file | str starts-with "file://") {
        let host = get_hostname
        mut f = $file
        $f = ($f | str replace --regex "^file://localhost" "")
        $f = ($f | str replace --regex $"^file://($host)" "")
        $f = ($f | str replace --regex "^file://" "")
        if not ($f | str starts-with "/") {
            return $f
        }
        $f = ($f | split row "#" | get 0)
        $f = ($f | split row "?" | get 0)
        $f = (percent_decode $f)
        return $f
    }
    $file
}
# Open on Cygwin
def --env open_cygwin [url: string] {
    let result = (^cygstart $url | complete)
    if ($result.exit_code) == 0 {
        exit_success
    } else {
        exit_failure_operation_failed
    }
}
# Open on Darwin
def --env open_darwin [url: string] {
    let result = (^open $url | complete)
    if ($result.exit_code) == 0 {
        exit_success
    } else {
        exit_failure_operation_failed
    }
}
# Open on KDE
def --env open_kde [url: string] {
    let version = ($env.KDE_SESSION_VERSION? | default "")
    let cmd = match $version {
        "" => "kfmclient"
        "5" => "kde-open5"
        _ => "kde-open"
    }
    let result = if $cmd == "kfmclient" {
        ^kfmclient exec $url | complete
    } else {
        ^$cmd $url | complete
    }
    if ($result.exit_code) == 0 {
        exit_success
    } else {
        exit_failure_operation_failed
    }
}
# Open on Deepin
def --env open_deepin [url: string] {
    if (which dde-open | is-not-empty) {
        let result = (^dde-open $url | complete)
        if ($result.exit_code) == 0 {
            exit_success
        }
        exit_failure_operation_failed
    }
    open_generic $url
}
# Open on GNOME 3
def --env open_gnome3 [url: string] {
    let result = if (which gio | is-not-empty) {
        (^gio open $url | complete)
    } else {
        return (open_generic $url)
    }
    if ($result.exit_code) == 0 {
        exit_success
    } else {
        exit_failure_operation_failed
    }
}
# Open on GNOME
def --env open_gnome [url: string] {
    let result = if (which gio | is-not-empty) {
        (^gio open $url | complete)
    } else if (which gnome-open | is-not-empty) {
        (^gnome-open $url | complete)
    } else {
        return (open_generic $url)
    }
    if ($result.exit_code) == 0 {
        exit_success
    } else {
        exit_failure_operation_failed
    }
}
# Open on MATE
def --env open_mate [url: string] {
    let result = if (which gio | is-not-empty) {
        (^gio open $url | complete)
    } else if (which mate-open | is-not-empty) {
        (^mate-open $url | complete)
    } else {
        return (open_generic $url)
    }
    if ($result.exit_code) == 0 {
        exit_success
    } else {
        exit_failure_operation_failed
    }
}
# Open on XFCE
def --env open_xfce [url: string] {
    let result = if (which xfce-open | is-not-empty) {
        (^xfce-open $url | complete)
    } else if (which exo-open | is-not-empty) {
        (^exo-open $url | complete)
    } else if (which gio | is-not-empty) {
        (^gio open $url | complete)
    } else {
        return (open_generic $url)
    }
    if ($result.exit_code) == 0 {
        exit_success
    } else {
        exit_failure_operation_failed
    }
}
# Open on Enlightenment
def --env open_enlightenment [url: string] {
    let result = if (which enlightenment_open | is-not-empty) {
        (^enlightenment_open $url | complete)
    } else {
        return (open_generic $url)
    }
    if ($result.exit_code) == 0 {
        exit_success
    } else {
        exit_failure_operation_failed
    }
}
# Open using the D-Bus desktop portal
def --env open_portal [url: string] {
    # Normalize local paths into file:// URIs.
    let target = if (is_file_url_or_path $url) {
        let file = (file_url_to_path $url)
        check_input_file $file
        $"file://(($file | path expand))"
    } else {
        $url
    }
    let ok = (try {
        dbus call --dest=org.freedesktop.portal.Desktop --timeout=5sec /org/freedesktop/portal/desktop org.freedesktop.portal.OpenURI OpenURI "" $target {}
        true
    } catch { false })
    if $ok {
        exit_success
    } else {
        exit_failure_operation_failed
    }
}
# Decode a file:// URI to a local path, but only if it has no host or names
# this machine.
def decode_local_file_uri [uri: string, hostname: string]: nothing -> string {
    if not ($uri | str starts-with "file://") { return "" }
    let rest = ($uri | str substring 7..)
    # Strip query/fragment, anything before is the [host]/path
    let stripped = ($rest | str replace --regex '[?#].*$' '')
    let slash = ($stripped | str index-of "/")
    let host = if $slash < 0 { $stripped } else {
        $stripped | str substring 0..$slash
    }
    let path = if $slash < 0 { "" } else {
        $stripped | str substring $slash..
    }
    if not ($host | is-empty) and $host != "localhost" and $host != $hostname { return "" }
    if ($path | is-empty) { return "" }
    percent_decode $path
}
# Build the argv for opening `file`/`uri` with `desktop_file`. Returns
# {ok: bool, message: string, cmd: string, args: list<string>}.
def --env compute_desktop_command [
    desktop_file: string
    file: string
    uri: string
    hostname: string
]: nothing -> record {
    # files[] / uris[] mirror the awk semantics. A URI argument can be a
    # space-separated list, and we also try to decode each into a local path.
    let split_uris = if ($uri | is-empty) { [] } else {
        $uri | split row " " | where { not ($in | is-empty) }
    }
    mut files: list<string> = []
    mut uris: list<string> = $split_uris
    for u in $split_uris {
        if not ($file | is-empty) {
            let decoded = (decode_local_file_uri $u $hostname)
            if not ($decoded | is-empty) {
                $files = ($files | append $decoded)
            }
        }
    }
    if not ($file | is-empty) {
        $files = ($files | append $file)
        if ($uris | is-empty) {
            $uris = [$file]
        }
    }
    # Parsing the Desktop Entry (locale-resolved Exec/Icon/Name/Terminal) and the
    # field-code expansion both live in the `xdg` plugin now; a read error or a
    # missing [Desktop Entry] group surfaces as a thrown error we turn into the
    # same {ok:false} record the caller expects.
    let parsed = try {
        xdg desktop parse $desktop_file
    } catch {|e|
        {error: $"xdg-open: ($e.msg)"}
    }
    if ($parsed.error? | is-not-empty) {
        return {ok: false, message: $parsed.error, cmd: "", args: []}
    }
    let exec_value = ($parsed.exec | default "")
    if ($exec_value | is-empty) {
        return {
            ok: false
            message: "xdg-open: No Exec= line found in main section of desktop file!"
            cmd: ""
            args: []
        }
    }
    let icon_value = ($parsed.icon | default "")
    let name_value = ($parsed.name | default "")
    # `expand-exec` enforces the spec's quoting, one-file-code, and
    # standalone-%F/%U/%i rules; %i only emits `--icon` when an Icon= exists.
    let exp = try {
        let base = if ($icon_value | is-empty) {
            xdg desktop expand-exec $exec_value --files $files --urls $uris --name $name_value --desktop-path $desktop_file
        } else {
            xdg desktop expand-exec $exec_value --files $files --urls $uris --icon $icon_value --name $name_value --desktop-path $desktop_file
        }
        let full = if $parsed.terminal { ["xdg-terminal"] ++ $base } else { $base }
        {ok: true, argv: $full, message: ""}
    } catch {|e|
        {ok: false, argv: [], message: $"xdg-open: ($e.msg)"}
    }
    if not $exp.ok {
        return {ok: false, message: $exp.message, cmd: "", args: []}
    }
    let expanded = $exp.argv
    if ($expanded | is-empty) {
        return {
            ok: false
            message: "xdg-open: Exec line expanded to no arguments"
            cmd: ""
            args: []
        }
    }
    {
        ok: true
        message: ""
        cmd: ($expanded | get 0)
        args: ($expanded | skip 1)
    }
}
# Recursively search .desktop file
# Open a file using a desktop file entry
# (desktop_file, file, uri (optional))
def --env open_with_desktop_file [desktop_file: string, file: string, uri: string = ""] {
    let hostname = (get_hostname)
    let result = (compute_desktop_command $desktop_file $file $uri $hostname)
    if not $result.ok {
        print --stderr $result.message
        exit_failure_operation_failed
    }
    ^$result.cmd ...$result.args
    if $env.LAST_EXIT_CODE != 0 {
        exit_failure_operation_failed
    }
    exit_success
}
# Search desktop files for default application
# Handles both vendor-app.desktop and vendor/app.desktop paths
def --env search_desktop_file [
    default: string
    dir: string
    target: string
    target_uri: string = ""
] {
    let candidate = ($dir | path join $default)
    if not ((is-file $candidate) and ($candidate | path parse | get extension) == "desktop") {
        # Try vendor/app.desktop, deriving it by swapping the first `-` for a `/`.
        let alt_name = ($default | str replace "-" "/")
        let alt_path = ($dir | path join $alt_name)
        if ((is-file $alt_path) and ($alt_path | path parse | get extension) == "desktop") {
            open_with_desktop_file $alt_path $target $target_uri
            exit_success
        }
    } else {
        open_with_desktop_file $candidate $target $target_uri
        exit_success
    }
    for d in (ls $dir) {
        if (is-dir $d.name) {
            search_desktop_file $default $d.name $target $target_uri
        }
    }
}
# Open using xdg-mime
# (file (or empty), mimetype, optional url)
def --env open_generic_xdg_mime [file: string, filetype: string, url: string = ""] {
    let default_app = (
        ^xdg-mime query default $filetype | complete | get stdout | str trim
    )
    if ($default_app | is-empty) { return }
    let xdg_user_dir = if not ($env.XDG_DATA_HOME? == null) { $env.XDG_DATA_HOME } else {
        $env.HOME | path join ".local" "share"
    }
    let xdg_system_dirs = if not ($env.XDG_DATA_DIRS? == null) { $env.XDG_DATA_DIRS } else { "/usr/local/share/:/usr/share/" }
    let search_dirs = ($"($xdg_user_dir):($xdg_system_dirs)" | split row ":")
    for dir in $search_dirs {
        let app_dir = ($dir | path join "applications")
        if (is-dir $app_dir) {
            search_desktop_file $default_app $app_dir $file $url
        }
    }
}
# Open an url using the x-scheme-handler/<scheme> dummy mimetype
def --env open_generic_xdg_x_scheme_handler [url: string] {
    let scheme = (
        $url | parse --regex '^(?P<s>[[:alpha:]][[:alnum:]+.\-]*):' | get s? | get 0? | default ""
    )
    if ($scheme | is-empty) { return }
    let filetype = $"x-scheme-handler/($scheme)"
    open_generic_xdg_mime $url $filetype
}
# Check single argument
def has_single_argument [arg_count: int] { $arg_count == 1 }
# Open using BROWSER env var
def --env open_envvar [url: string] {
    if ($env.BROWSER? | default "" | is-empty) { return }
    let browsers = ($env.BROWSER | split row ":")
    for browser in $browsers {
        if ($browser | is-empty) { continue }
        if ($browser | str contains "%s") {
            # Substitute %s with the URL, then split into argv and exec directly.
            let formatted = ($browser | str replace "%s" $url)
            if ($formatted | is-empty) { continue }
            let parts = ($formatted | split row " " | where { ($in | is-not-empty) })
            if ($parts | is-empty) { continue }
            let exe = ($parts | get 0)
            let extra = ($parts | skip 1)
            let result = (^$exe ...$extra | complete)
            if ($result.exit_code) == 0 {
                exit_success
            }
        } else {
            # Split on whitespace so flags after the executable end up as their
            # own argv entries.
            let parts = ($browser | split row " " | where { ($in | is-not-empty) })
            if ($parts | is-empty) { continue }
            let exe = ($parts | get 0)
            let extra = ($parts | skip 1)
            let result = (^$exe ...$extra $url | complete)
            if ($result.exit_code) == 0 {
                exit_success
            }
        }
    }
}
# Open on WSL
def --env open_wsl [url: string] {
    let result = if (is_file_url_or_path $url) {
        let raw_path = (file_url_to_path $url)
        let win_path_result = (^wslpath -aw $raw_path | complete)
        if ($win_path_result.exit_code) != 0 {
            exit_failure_operation_failed
        }
        let win_path = ($win_path_result.stdout | str trim)
        (^explorer.exe $win_path | complete)
    } else {
        (^rundll32.exe url.dll,FileProtocolHandler $url | complete)
    }
    if ($result.exit_code) == 0 {
        exit_success
    } else {
        exit_failure_operation_failed
    }
}
# Generic open fallback
def --env open_generic [url: string] {
    if (is_file_url_or_path $url) {
        let file = (file_url_to_path $url)
        check_input_file $file
        if (has_display) {
            let filetype = (^xdg-mime query filetype $file | complete | get stdout | str trim | split row ";" | get 0)
            if (has_url_scheme $url) {
                open_generic_xdg_mime $file $filetype $url
            } else {
                open_generic_xdg_mime $file $filetype
            }
        }
        if (which run-mailcap | is-not-empty) {
            let result = (^run-mailcap --action=view $file | complete)
            if ($result.exit_code) == 0 {
                exit_success
            }
        }
        if (has_display) and (which mimeopen | is-not-empty) {
            let result = (^mimeopen -L -n $file | complete)
            if ($result.exit_code) == 0 {
                exit_success
            }
        }
    }
    if (has_display) {
        open_generic_xdg_x_scheme_handler $url
    }
    if not ($env.BROWSER? | default "" | is-empty) {
        open_envvar $url
    }
    if ($env.BROWSER? | default "" | is-empty) {
        $env.BROWSER = "www-browser:links2:elinks:links:lynx:w3m"
        if (has_display) {
            $env.BROWSER = $"x-www-browser:firefox:iceweasel:seamonkey:mozilla:epiphany:konqueror:chromium:chromium-browser:google-chrome:($env.BROWSER)"
        }
    }
    open_envvar $url
    exit_failure_operation_impossible $"no method available for opening '($url)'"
}
# Open on LXDE
def --env open_lxde [url: string] {
    if (which pcmanfm | is-not-empty) and (is_file_url_or_path $url) {
        mut file = (file_url_to_path $url)
        if not ($file | str starts-with "/") {
            $file = ([
                $"(pwd)"
                $file
            ] | path join)
        }
        let result = (^pcmanfm $file | complete)
        if ($result.exit_code) == 0 {
            exit_success
        }
        exit_failure_operation_failed
    }
    open_generic $url
}
# Open on LXQt
def --env open_lxqt [url: string] {
    if (which qtxdg-mat | is-not-empty) {
        let result = (^qtxdg-mat open $url | complete)
        if ($result.exit_code) == 0 {
            exit_success
        }
        exit_failure_operation_failed
    }
    exit_failure_operation_impossible "no method available for opening '$url'"
}
# Dispatch to correct opener based on DE
def --env open_one_argument [url: string] { match ($env.DE? | default "") {
    "kde" => { open_kde $url }
    "deepin" => { open_deepin $url }
    "gnome3" => { open_gnome3 $url }
    "cinnamon" => { open_gnome3 $url }
    "budgie" => { open_gnome3 $url }
    "gnome" => { open_gnome $url }
    "mate" => { open_mate $url }
    "xfce" => { open_xfce $url }
    "lxde" => { open_lxde $url }
    "lxqt" => { open_lxqt $url }
    "enlightenment" => { open_enlightenment $url }
    "cygwin" => { open_cygwin $url }
    "darwin" => { open_darwin $url }
    "flatpak" => { open_portal $url }
    "toolbx" => { open_portal $url }
    "wsl" => { open_wsl $url }
    "generic" => { open_generic $url }
} }
# xdg-open - opens a file or URL in the user's preferred application
# Synopsis: xdg-open { file | URL }
# Synopsis: xdg-open { --help | --manual | --version }
def --wrapped main [...args] {
    let args = ($args | each { into string })
    handle_standard_options "xdg-open" $args [
        "xdg-open - opens a file or URL in the user's preferred application"
        ""
        "Synopsis"
        ""
        "xdg-open { file | URL }"
        ""
        "xdg-open { --help | --manual | --version }"
    ]
    if ($args | is-empty) {
        exit_failure_syntax
    }
    detectDE
    if ($env.DE? == null) or ($env.DE | is-empty) {
        $env.DE = "generic"
    }
    # Allow forcing portal use via environment variable
    if ($env.NIXOS_XDG_OPEN_USE_PORTAL? != null) and ($env.NIXOS_XDG_OPEN_USE_PORTAL != "") {
        $env.DE = "flatpak"
    }
    DEBUG 2 $"Selected DE ($env.DE)"
    # Sanitize BROWSER variable
    if not ($env.BROWSER? == null) {
        if ($env.BROWSER | str contains ":xdg-open") {
            $env.BROWSER = ($env.BROWSER | str replace --all ":xdg-open" "" | str replace --all "xdg-open:" "")
        }
        if $env.BROWSER == "xdg-open" {
            $env.BROWSER = ""
        }
    }
    mut nowait = false
    mut err = 0
    mut remaining_args = $args
    while not ($remaining_args | is-empty) {
        let parm = ($remaining_args | get 0)
        $remaining_args = ($remaining_args | skip 1)
        if ($parm == "--nowait") {
            $nowait = true
        } else if ($parm == "--") {
            break
        } else if ($parm | str starts-with "-") {
            exit_failure_syntax $"unexpected option '($parm)'"
        } else {
            let remaining = ($remaining_args | length)
            if $nowait or ($remaining > 0) {
                open_one_argument $parm
            } else {
                open_one_argument $parm
            }
        }
    }
    exit $err
}
