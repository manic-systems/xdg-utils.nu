# Common utility functions for xdg-utils scripts in Nushell
export const XDG_UTILS_VERSION "1.2.1"
# Debug output based on XDG_UTILS_DEBUG_LEVEL
export def DEBUG [level: int, ...args] {
    let raw = ($env.XDG_UTILS_DEBUG_LEVEL? | default "")
    if ($raw | is-empty) { return }
    let current = (try {
        $raw | into int
    } catch { 0 })
    if $current >= $level {
        print --stderr ($args | str join " ")
    }
}
export def handle_standard_options [tool: string, args: list<any>, help_lines: list<string>] {
    if (($args | length) != 1) {
        return
    }
    let arg = ($args | get 0)
    if ($arg == "--help") or ($arg == "-h") {
        print ($help_lines | str join (char nl))
        exit 0
    }
    if $arg == "--manual" {
        print $"Use 'man ($tool)' for additional info."
        exit 0
    }
    if $arg == "--version" {
        print $"($tool) ($XDG_UTILS_VERSION)"
        exit 0
    }
}
# Resolve an XDG user directory (such as DESKTOP, DOWNLOAD, etc.) by parsing
# `~/.config/user-dirs.dirs` directly. Returns the fallback when the file is
# missing or the key isn't set.
export def xdg_user_dir [key: string, fallback: string]: nothing -> string {
    let cfg = (get_xdg_config_home | path join "user-dirs.dirs")
    if (not (is-file $cfg)) { return $fallback }
    let key_re = '^XDG_' + $key + '_DIR='
    let line = (
        open --raw $cfg | lines | where { ($in | str trim) =~ $key_re } | get 0?
    )
    if $line == null { return $fallback }
    let value = (
        $line | parse --regex ($key_re + '"(?P<v>[^"]*)"') | get v? | get 0? | default ""
    )
    if ($value | is-empty) { return $fallback }
    $value | str replace --regex '^\$HOME' $env.HOME
}
# Returns the first word of text (handles backslashes but not quote marks)
# Read the calling process's effective UID directly from /proc.
export def current_uid []: nothing -> int {
    open --raw /proc/self/status | lines | where {|l| $l | str starts-with "Uid:" } | get 0? | default "Uid:\t0" | parse --regex 'Uid:\s+(?P<u>\d+)' | get u.0? | default "0" | into int
}
export def first_word [text: string] {
    let parts = ($text | split row " " | where {|x| not ($x | is-empty) })
    if not ($parts | is-empty) { $parts.0 } else { "" }
}
# Return the lines inside a single `[Section]` block of a Desktop Entry file,
# stopping at the next `[Other Section]` header.
export def desktop_section_lines [path: string, section: string]: nothing -> list<string> {
    let header = $"[($section)]"
    let all = (open --raw $path | lines)
    let start = (
        $all | enumerate | where {|e| $e.item == $header } | get index.0?
    )
    if $start == null { return [] }
    let tail = ($all | skip ($start + 1))
    let end = (
        $tail | enumerate | where {|e| $e.item | str starts-with "[" } | get index.0?
    )
    if $end == null { return $tail }
    $tail | take $end
}
# Pull the text content out of every occurrence of `<tag>...</tag>` in an XML
# file, one line per match. Handles the simple flat menu/directory files xdg
# generates without needing a real XML parser.
export def extract_xml_tag_contents [path: string, tag: string]: nothing -> string {
    open --raw $path | split row "<" | each {|rec|
        if not ($rec | str starts-with $tag) { return null }
        let gt = ($rec | str index-of ">")
        if $gt < 0 { return null }
        $rec | str substring (($gt + 1)..)
    } | where {|x| $x != null and not ($x | is-empty) } | str join "\n"
}
# Decode a percent-encoded string, walking the bytes so that multi-byte UTF-8
# sequences survive intact.
export def percent_decode [s: string]: nothing -> string {
    let hex_pairs = ($s | parse --regex '%(?P<h>[a-fA-F0-9]{2})' | get h)
    if ($hex_pairs | is-empty) { return $s }
    let parts = ($s | split row --regex '%[a-fA-F0-9]{2}')
    let binary = ($hex_pairs | enumerate | reduce --fold (($parts | get 0) | encode utf-8) {|it, acc|
            let byte = ($it.item | decode hex | collect)
            let next = (($parts | get ($it.index + 1) | default "") | encode utf-8)
            $acc ++ $byte ++ $next
        })
    $binary | decode
}
# Symlink-resolving variants of `path type`, since the builtin reports a link
# as "symlink" rather than the kind of thing it points to.
export def is-file [path: string]: nothing -> bool {
    if not ($path | path exists) { return false }
    ($path | path expand | path type) == "file"
}
export def is-dir [path: string]: nothing -> bool {
    if not ($path | path exists) { return false }
    ($path | path expand | path type) == "dir"
}
export def is-readable [path: string]: nothing -> bool {
    if not ($path | path exists) { return false }
    try {
        open --raw $path | first 0 | ignore
        true
    } catch { false }
}
# For directories, probe by creating and removing a tempfile inside. For
# regular files, walk the mode bits and decide based on whether we own the
# file, share its group, or fall to the "other" class.
export def is-writable [path: string]: nothing -> bool {
    if not ($path | path exists) { return false }
    if (is-dir $path) {
        return (try {
            let f = (mktemp --tmpdir-path $path .xdg-utils-w.XXXX)
            rm $f
            true
        } catch { false })
    }
    mode_allows_for_caller $path "w"
}
export def is-executable [path: string]: nothing -> bool {
    if (not (is-file $path)) { return false }
    mode_allows_for_caller $path "x"
}
# Returns whether the calling user has the given mode bit set (`r`/`w`/`x`) on
# `path`, considering owner, group, then other.
def mode_allows_for_caller [path: string, bit: string]: nothing -> bool {
    let info = (ls --long $path | first)
    let mode = ($info.mode | default "---------")
    let owner_slot = ($mode | str substring 0..3)
    let group_slot = ($mode | str substring 3..6)
    let other_slot = ($mode | str substring 6..9)
    let uid = (current_uid)
    if $uid == 0 { return ($bit != "x" or ($mode | str contains "x")) }
    let file_user = ($info.user? | default "")
    if $file_user == ($env.USER? | default "") {
        return ($owner_slot | str contains $bit)
    }
    # Group match — best-effort via `id -Gn` would need an external; fall back
    # to "other" which is the safe lower bound. Anyone with stricter needs can
    # opt into a non-default umask before invoking xdg-utils.
    $other_slot | str contains $bit
}
# Map a binary to a .desktop file
export def --env binary_to_desktop_file [command_or_path: string] {
    if ($command_or_path | is-empty) {
        DEBUG 2 "binary_to_desktop_file argument is empty"
        return
    }
    let search = (if not ($env.XDG_DATA_HOME? == null) { $env.XDG_DATA_HOME } else {
        $env.HOME | path join ".local" "share"
    } | append (if not ($env.XDG_DATA_DIRS? == null) { $env.XDG_DATA_DIRS } else { "/usr/local/share:/usr/share" }))
    let which_result = (which $command_or_path)
    if ($which_result | is-empty) { return }
    let binary = ($which_result | get 0.path)
    let binary_path = (xdg_realpath $binary)
    let base = ($binary_path | path parse | get stem)
    let search_dirs = ($search | split row ":")
    for dir in $search_dirs {
        if ($dir | is-empty) { continue }
        if (not (is-dir ($dir | path join "applications"))) and (not (is-dir ($dir | path join "applnk"))) { continue }
        for file_path in (
            glob ($dir | path join "applications" "*.desktop") | append (glob ($dir | path join "applications" "*" "*.desktop")) | append (glob ($dir | path join "applnk" "*.desktop")) | append (glob ($dir | path join "applnk" "*" "*.desktop"))
        ) {
            if not ((is-file $file_path) and ($file_path | path parse | get extension) == "desktop") { continue }
            if not (is-readable $file_path) { continue }
            let file_lines = (open --raw $file_path | lines)
            # Check if the Exec line contains the base binary name
            if not ($file_lines | any {|l| $l =~ $"Exec.*($base)" }) { continue }
            # Skip hidden desktop files
            if ($file_lines | any {|l| $l =~ '^(NoDisplay|Hidden)=true' }) { continue }
            # Get the command from Exec line
            let exec_lines = ($file_lines | where {|l| $l =~ '^Exec(\[[^]=]*\])?=' })
            if ($exec_lines | is-empty) { continue }
            let exec_line = (
                $exec_lines | get 0 | split row "=" | skip 1 | str join "=" | split row " " | where { not ($in | is-empty) } | get 0 | str trim
            )
            let which_exec = (which $exec_line)
            if ($which_exec | is-empty) { continue }
            let command = ($which_exec | get 0.path)
            if (xdg_realpath $command) == $binary_path {
                # Fix double slashes
                print ($file_path | str replace --all --regex "//+" "/")
                return
            }
        }
    }
}
# Map a .desktop file to its binary. Returns the absolute path, or null.
export def --env desktop_file_to_binary [desktop_file: string] {
    DEBUG 1 $"desktop_file_to_binary '($desktop_file)'"
    if ($desktop_file | is-empty) {
        DEBUG 2 "desktop_file_to_binary argument is empty"
        return null
    }
    let search = (if not ($env.XDG_DATA_HOME? == null) { $env.XDG_DATA_HOME } else {
        $env.HOME | path join ".local" "share"
    } | append (if not ($env.XDG_DATA_DIRS? == null) { $env.XDG_DATA_DIRS } else { "/usr/local/share:/usr/share" }))
    # Normalize to the full <name>.desktop filename used on disk
    let desktop = if ($desktop_file | str ends-with ".desktop") { $desktop_file } else { $"($desktop_file).desktop" }
    let search_dirs = ($search | split row ":")
    for dir in $search_dirs {
        DEBUG 2 $"Searching in '($dir)/{applications,applnk}'"
        if ($dir | is-empty) { continue }
        let apps_dir = ($dir | path join "applications")
        let applnk_dir = ($dir | path join "applnk")
        let apps_exists = (is-dir $apps_dir)
        let applnk_exists = (is-dir $applnk_dir)
        if not $apps_exists and not $applnk_exists { continue }
        mut file_path = ($dir | path join "applications" $desktop)
        mut found_file_path = false
        # Check if desktop file contains vendor prefix (contains -)
        if ($desktop | str contains "-") {
            let stem = ($desktop | str substring 0..(($desktop | str length) - (".desktop" | str length)))
            let vendor = ($stem | split row "-" | get 0)
            let app = $"($stem | split row "-" | skip 1 | str join "-").desktop"
            if (is-file ($dir | path join "applications" $vendor $app)) {
                $file_path = ($dir | path join "applications" $vendor $app)
                $found_file_path = true
            } else if (is-file ($dir | path join "applnk" $vendor $app)) {
                $file_path = ($dir | path join "applnk" $vendor $app)
                $found_file_path = true
            }
        }
        # If not found with vendor prefix, search in subdirectories
        if not $found_file_path {
            for indir in [
                ($dir | path join "applications")
                ($dir | path join "applications" "*")
                ($dir | path join "applnk")
                ($dir | path join "applnk" "*")
            ] {
                DEBUG 4 $"Does file exist? '($indir)/($desktop)'"
                let test_path = ($indir | path join $desktop)
                if ((is-file $test_path)) {
                    $file_path = $test_path
                    $found_file_path = true
                    break
                }
            }
        }
        # If we found a readable file, extract the Exec line
        if $found_file_path {
            if not (is-readable $file_path) { continue }
            DEBUG 2 $"Checking desktop file '($file_path)'"
            # Get the command name from the correct Exec
            # Note: Ignoring quoting and escape sequences here, see #253
            let entry_lines = (desktop_section_lines $file_path "Desktop Entry")
            let exec_line = ($entry_lines | where {|l| $l =~ '^Exec[[:space:]]*=' } | get 0? | default "")
            let binary = if ($exec_line | is-empty) {
                ""
            } else {
                $exec_line | split row "=" | skip 1 | str join "=" | str trim | split row --regex '[[:space:]]+' | get 0? | default ""
            }
            if ($binary | is-empty) {
                DEBUG 2 "No or empty Exec key in .desktop file. Search failed."
                return null
            }
            DEBUG 2 $"Found command: ($binary)"
            let resolved = (xdg_which $binary)
            DEBUG 2 $"Resolved to command to file: '($resolved)'"
            if ($resolved | is-not-empty) {
                return (xdg_realpath $resolved)
            }
        }
    }
    null
}
# Exit with success
export def --env exit_success [...messages] {
    if not ($messages | is-empty) {
        print $messages.0
        print ""
    }
    exit 0
}
# Exit with syntax error
export def --env exit_failure_syntax [...messages] {
    if not ($messages | is-empty) {
        print --stderr $"xdg-utils: ($messages.0)"
    }
    print --stderr "Try 'xdg-utils --help' for more information."
    exit 1
}
# Exit with file missing error
export def --env exit_failure_file_missing [...messages] {
    if not ($messages | is-empty) {
        print --stderr $"xdg-utils: ($messages.0)"
    }
    exit 2
}
# Exit with operation impossible error
export def --env exit_failure_operation_impossible [...messages] {
    if not ($messages | is-empty) {
        print --stderr $"xdg-utils: ($messages.0)"
    }
    exit 3
}
# Exit with operation failed error
export def --env exit_failure_operation_failed [...messages] {
    if not ($messages | is-empty) {
        print --stderr $"xdg-utils: ($messages.0)"
    }
    exit 4
}
# Exit with file permission read error
export def --env exit_failure_file_permission_read [...messages] {
    if not ($messages | is-empty) {
        print --stderr $"xdg-utils: ($messages.0)"
    }
    exit 5
}
# Exit with file permission write error
export def --env exit_failure_file_permission_write [...messages] {
    if not ($messages | is-empty) {
        print --stderr $"xdg-utils: ($messages.0)"
    }
    exit 6
}
# Check if input file exists and is readable
export def --env check_input_file [path: string] {
    if ((not (is-file $path))) {
        exit_failure_file_missing $"file '($path)' does not exist"
    }
    if not (is-readable $path) {
        exit_failure_file_permission_read $"no permission to read file '($path)'"
    }
}
# Check vendor prefix on filename
export def --env check_vendor_prefix [path: string] {
    let file_label = "filename"
    let file = ($path | path parse | get stem)
    if not ($file | str contains "-") {
        print --stderr $"xdg-utils: ($file_label) '($file)' does not have a proper vendor prefix"
        print --stderr "A vendor prefix consists of alpha characters ([a-zA-Z]) and is terminated"
        print --stderr $"with a dash (-). An example ($file_label) is 'example-($file)'"
        print --stderr "Use --novendor to override or 'xdg-utils --manual' for additional info."
        exit 1
    }
}
# Check if output file is writable
export def --env check_output_file [path: string] {
    if ((is-file $path)) {
        if not (is-writable $path) {
            exit_failure_file_permission_write $"no permission to write to file '($path)'"
        }
    } else {
        let dir = ($path | path dirname)
        if not (is-writable $dir) {
            exit_failure_file_permission_write $"no permission to create file '($path)'"
        }
    }
}
# Set up output redirection based on debug level
# If debug level is < 1, be silent; otherwise output to stderr
export def --env setup_xdg_redirect [] {
    let raw = ($env.XDG_UTILS_DEBUG_LEVEL? | default "")
    let level = if ($raw | is-empty) { 0 } else {
        try {
            $raw | into int
        } catch { 0 }
    }
    if $level < 1 {
        $env.XDG_UTILS_REDIRECT_OUTPUT = "/dev/null"
    } else {
        $env.XDG_UTILS_REDIRECT_OUTPUT = "stderr"
    }
}
# Checks for known desktop environments
# set variable DE to the desktop environments name, lowercase
# Don't forget to update the manpage!
export def --env detectDE [] {
    # Tool specific desktop override
    # General desktop override
    if not ($env.XDG_UTILS_OVERRIDE_DE? == null) {
        $env.DE = $env.XDG_UTILS_OVERRIDE_DE
        return
    }
    # Check for toolbx first
    if ((is-file $"/run/.toolboxenv")) {
        $env.DE = "toolbx"
        return
    }
    # Check XDG_CURRENT_DESKTOP
    if not ($env.XDG_CURRENT_DESKTOP? == null) {
        let desktops = ($env.XDG_CURRENT_DESKTOP | split row ":")
        for desktop in $desktops {
            match $desktop {
                "Cinnamon" => { 
                # only recently added to menu-spec, pre-spec X- still in use
                $env.DE = "cinnamon" }
                "X-Cinnamon" => { $env.DE = "cinnamon" }
                "ENLIGHTENMENT" => { $env.DE = "enlightenment" }
                "GNOME" => { $env.DE = "gnome" }
                "KDE" => { $env.DE = "kde" }
                "DEEPIN" => { $env.DE = "deepin" }
                "Deepin" => { $env.DE = "deepin" }
                "deepin" => { $env.DE = "deepin" }
                "DDE" => { $env.DE = "deepin" }
                "LXDE" => { $env.DE = "lxde" }
                "LXQt" => { $env.DE = "lxqt" }
                "MATE" => { $env.DE = "mate" }
                "XFCE" => { $env.DE = "xfce" }
                "Budgie" => { $env.DE = "budgie" }
                "X-Generic" => { $env.DE = "generic" }
                _ => { }
            }
            if not ($env.DE? == null) { break }
        }
    }
    # classic fallbacks
    if ($env.DE? == null) and not ($env.KDE_FULL_SESSION? == null) { $env.DE = "kde" }
    if ($env.DE? == null) and not ($env.GNOME_DESKTOP_SESSION_ID? == null) { $env.DE = "gnome" }
    if ($env.DE? == null) and not ($env.MATE_DESKTOP_SESSION_ID? == null) { $env.DE = "mate" }
    if ($env.DE? == null) and ((^gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.GetNameOwner '"org.gnome.SessionManager"' | complete).exit_code == 0) { $env.DE = "gnome" }
    if ($env.DE? == null) and not ($env.DESKTOP? == null) and ($env.DESKTOP | str starts-with "Enlightenment") { $env.DE = "enlightenment" }
    if ($env.DE? == null) and not ($env.LXQT_SESSION_CONFIG? == null) { $env.DE = "lxqt" }
    # fallback to checking $DESKTOP_SESSION
    if ($env.DE? == null) {
        if not ($env.DESKTOP_SESSION? == null) {
            match $env.DESKTOP_SESSION {
                "gnome" => { $env.DE = "gnome" }
                "LXDE" => { $env.DE = "lxde" }
                "Lubuntu" => { $env.DE = "lxde" }
                "MATE" => { $env.DE = "mate" }
                "xfce" => { $env.DE = "xfce" }
                "xfce4" => { $env.DE = "xfce" }
                "Xfce Session" => { $env.DE = "xfce" }
                _ => { }
            }
        }
    }
    # fallback to kernel name for other platforms
    if ($env.DE? == null) {
        let os = (sys host | get name)
        if ($os | str starts-with "CYGWIN") { $env.DE = "cygwin" }
        if ($env.DE? == null) and ($os == "Darwin") { $env.DE = "darwin" }
        if ($env.DE? == null) and ($os == "Linux") {
            if ((is-file "/proc/version")) and ((open --raw /proc/version | str contains "microsoft")) and ((which explorer.exe | is-not-empty)) {
                $env.DE = "wsl"
            }
        }
    }
    # gnome-default-applications-properties is only available in GNOME 2.x
    # but not in GNOME 3.x
    if ($env.DE? | default "") == "gnome" {
        if (which gnome-default-applications-properties | is-empty) {
            $env.DE = "gnome3"
        }
    }
    # Flatpak detection
    if ((is-file $"/.flatpak-info")) {
        $env.DE = "flatpak"
    }
}
# kfmclient exec/openURL can give bogus exit value in KDE <= 3.5.4
# It also always returns 1 in KDE 3.4 and earlier
# Simply return 0 in such case
export def --env kfmclient_fix_exit_code [exit_code: int] {
    let version_result = (with-env { LC_ALL: "C.UTF-8" } { ^kde-config --version } | complete)
    if ($version_result.exit_code) != 0 {
        return $exit_code
    }
    let version_line = (
        $version_result.stdout | lines | where { $in | str starts-with "KDE" } | get 0?
    )
    if ($version_line | is-empty) { return $exit_code }
    let parts = (
        $version_line | split row " " | last | split row "."
    )
    let major = (
        $parts | get 0? | default "0" | into int
    )
    let minor = (
        $parts | get 1? | default "0" | into int
    )
    let release = (
        $parts | get 2? | default "0" | into int
    )
    if $major > 3 { return $exit_code }
    if $minor > 5 { return $exit_code }
    if $release > 4 { return $exit_code }
    return 0
}
# Check if we have a display
export def --env has_display [] {
    let disp = ($env.DISPLAY? | default "")
    let wayland = ($env.WAYLAND_DISPLAY? | default "")
    not ($disp | is-empty) or not ($wayland | is-empty)
}
# Resolve a path through any symlinks and to an absolute location. Returns
# nothing when the path doesn't exist, matching the previous external-realpath
# contract.
export def xdg_realpath [path: string]: nothing -> string {
    if not ($path | path exists) { return "" }
    $path | path expand
}
# The `which` command but as a shell implementation.
# Returns either the path of the resolved binary or nothing, because
# command -v will also happily resolve to builtins, aliases, or functions.
export def --env xdg_which [command: string] {
    if ($command | is-empty) { return null }
    if ($command | str contains "/") {
        if (is-executable $command) {
            return (xdg_realpath $command)
        }
        return null
    }
    for p in ($env.PATH | split row ":") {
        let full_path = ($p | path join $command)
        if (is-executable $full_path) {
            return $full_path
        }
    }
    null
}
# Get XDG_CONFIG_HOME, falling back to ~/.config when it's unset or relative.
# Non-absolute values are not portable across applications so we ignore them.
export def get_xdg_config_home [] {
    if ($env.XDG_CONFIG_HOME? != null) and ($env.XDG_CONFIG_HOME | str starts-with "/") {
        $env.XDG_CONFIG_HOME
    } else {
        $env.HOME | path join ".config"
    }
}
