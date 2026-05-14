# Common utility functions for xdg-utils scripts in Nushell

export const XDG_UTILS_VERSION = "1.2.1"

# Debug output based on XDG_UTILS_DEBUG_LEVEL
export def DEBUG [level: int ...args] {
    let raw = ($env.XDG_UTILS_DEBUG_LEVEL? | default "")
    if ($raw | is-empty) { return }
    let current = (try { $raw | into int } catch { 0 })
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

# Returns the first word of text (handles backslashes but not quote marks)
export def first_word [text: string] {
    let parts = ($text | split row " " | where {|x| not ($x | is-empty) })
    if not ($parts | is-empty) { $parts.0 } else { "" }
}

export def is-readable [path: string]: nothing -> bool {
    (^test -r $path | complete).exit_code == 0
}
export def is-writable [path: string]: nothing -> bool {
    (^test -w $path | complete).exit_code == 0
}
export def is-executable [path: string]: nothing -> bool {
    (^test -x $path | complete).exit_code == 0
}

# Map a binary to a .desktop file
export def --env binary_to_desktop_file [command_or_path: string] {
    if ($command_or_path | is-empty) {
        DEBUG 2 "binary_to_desktop_file argument is empty"
        return
    }

    let search = (
        if not ($env.XDG_DATA_HOME? == null) { $env.XDG_DATA_HOME } else { $env.HOME | path join ".local" "share" }
        | append (
            if not ($env.XDG_DATA_DIRS? == null) { $env.XDG_DATA_DIRS } else { "/usr/local/share:/usr/share" }
        )
    )

    let which_result = (which $command_or_path)
    if ($which_result | is-empty) { return }
    let binary = ($which_result | get 0.path)
    let binary_path = (xdg_realpath $binary)
    let base = ($binary_path | path parse | get stem)

    let search_dirs = ($search | split row ":")

    for dir in $search_dirs {
        if ($dir | is-empty) { continue }
        if not ((($dir | path join "applications") | path type) == "dir") and not ((($dir | path join "applnk") | path type) == "dir") { continue }

        for file_path in (
            glob ($dir | path join "applications" "*.desktop")
            | append (glob ($dir | path join "applications" "*" "*.desktop"))
            | append (glob ($dir | path join "applnk" "*.desktop"))
            | append (glob ($dir | path join "applnk" "*" "*.desktop"))
        ) {
            if not (($file_path | path type) == "file" and ($file_path | path parse | get extension) == "desktop") { continue }
            if not (is-readable $file_path) { continue }

            # Check if the Exec line contains the base binary name
            let grep_result = (^grep -c $"Exec.*($base)" $file_path | complete)
            let exec_match = ($grep_result.exit_code) == 0
            if not $exec_match { continue }

            # Skip hidden desktop files
            let hidden_check = (^grep -E "^(NoDisplay|Hidden)=true" $file_path | complete)
            if ($hidden_check.exit_code) == 0 { continue }

            # Get the command from Exec line
            let exec_line_result = (^grep -E '^Exec(\[[^]=]*])?=' $file_path | complete)
            if ($exec_line_result.exit_code) != 0 { continue }
            let exec_line = ($exec_line_result.stdout | lines | get 0 | split row "=" | skip 1 | str join "=" | split row " " | where { not ($in | is-empty) } | get 0 | str trim)
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

    let search = (
        if not ($env.XDG_DATA_HOME? == null) { $env.XDG_DATA_HOME } else { $env.HOME | path join ".local" "share" }
        | append (
            if not ($env.XDG_DATA_DIRS? == null) { $env.XDG_DATA_DIRS } else { "/usr/local/share:/usr/share" }
        )
    )

    # Normalize to the full <name>.desktop filename used on disk
    let desktop = if ($desktop_file | str ends-with ".desktop") { $desktop_file } else { $"($desktop_file).desktop" }
    let search_dirs = ($search | split row ":")

    for dir in $search_dirs {
        DEBUG 2 $"Searching in '($dir)/{applications,applnk}'"
        if ($dir | is-empty) { continue }
        let apps_dir = ($dir | path join "applications")
        let applnk_dir = ($dir | path join "applnk")
        let apps_exists = ($apps_dir | path type) == "dir"
        let applnk_exists = ($applnk_dir | path type) == "dir"
        if not $apps_exists and not $applnk_exists { continue }

        mut file_path = ($dir | path join "applications" $desktop)
        mut found_file_path = false

        # Check if desktop file contains vendor prefix (contains -)
        if ($desktop | str contains "-") {
            let stem = ($desktop | str substring 0..(($desktop | str length) - (".desktop" | str length)))
            let vendor = ($stem | split row "-" | get 0)
            let app = $"($stem | split row "-" | skip 1 | str join "-").desktop"

            if (($dir | path join "applications" $vendor $app | path type) == "file") {
                $file_path = ($dir | path join "applications" $vendor $app)
                $found_file_path = true
            } else if (($dir | path join "applnk" $vendor $app | path type) == "file") {
                $file_path = ($dir | path join "applnk" $vendor $app)
                $found_file_path = true
            }
        }

        # If not found with vendor prefix, search in subdirectories
        if not $found_file_path {
            for indir in [
                ($dir | path join "applications"),
                ($dir | path join "applications" "*"),
                ($dir | path join "applnk"),
                ($dir | path join "applnk" "*")
            ] {
                DEBUG 4 $"Does file exist? '($indir)/($desktop)'"
                let test_path = ($indir | path join $desktop)
                if (($test_path | path type) == "file") {
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
            let awk_script = '/^\[/{in_entry=0} $0=="[Desktop Entry]"{in_entry=1} in_entry&&/^Exec[[:space:]]*=/{split($0,a,"="); cmd=a[2]; sub(/^[[:space:]]+/,"",cmd); match(cmd,/^[^[:space:]]+/); print substr(cmd,RSTART,RLENGTH); exit}'
            let binary_result = (^awk $awk_script $file_path | complete)

            if ($binary_result.exit_code) != 0 {
                DEBUG 2 "No or empty Exec key in .desktop file. Search failed."
                return null
            }

            let binary = (($binary_result.stdout) | str trim)
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
        print --stderr "Try 'xdg-utils --help' for more information."
    } else {
        print "Usage information would be shown here"
    }
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
    if (($path | path type) != "file") {
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
    if (($path | path type) == "file") {
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
    let level = if ($raw | is-empty) { 0 } else { try { $raw | into int } catch { 0 } }
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
    if (($"/run/.toolboxenv" | path type) == "file") {
        $env.DE = "toolbx"
        return
    }

    # Check XDG_CURRENT_DESKTOP
    if not ($env.XDG_CURRENT_DESKTOP? == null) {
        let desktops = ($env.XDG_CURRENT_DESKTOP | split row ":")
        for desktop in $desktops {
            match $desktop {
                # only recently added to menu-spec, pre-spec X- still in use
                "Cinnamon" => { $env.DE = "cinnamon" }
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

    # fallback to uname output for other platforms
    if ($env.DE? == null) {
        let uname_result = (^uname | complete)
        if ($uname_result.exit_code) == 0 {
            let os = ($uname_result.stdout | str trim)
            if ($os | str starts-with "CYGWIN") { $env.DE = "cygwin" }
            if ($env.DE? == null) and ($os == "Darwin") { $env.DE = "darwin" }
            if ($env.DE? == null) and ($os == "Linux") {
                if (("/proc/version" | path type) == "file") and ((open --raw /proc/version | str contains "microsoft")) and ((which explorer.exe | is-not-empty)) {
                    $env.DE = "wsl"
                }
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
    if (($"/.flatpak-info" | path type) == "file") {
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

    let version_line = ($version_result.stdout | lines | where { $in | str starts-with "KDE" } | get 0?)
    if ($version_line | is-empty) { return $exit_code }

    let parts = ($version_line | split row " " | last | split row ".")
    let major = ($parts | get 0? | default "0" | into int)
    let minor = ($parts | get 1? | default "0" | into int)
    let release = ($parts | get 2? | default "0" | into int)

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

# Prefixes path with "./" if it starts with "-"
# This is useful for programs to not confuse paths with options.
def unoption_path [path: string] {
    if ($path | str starts-with "-") {
        $"./($path)"
    } else {
        $path
    }
}

# Performs a symlink and relative path resolving for a single argument.
# This will always fail if the given file does not exist!
export def --env xdg_realpath [path: string] {
    # allow caching and external configuration
    if ($env.XDG_UTILS_REALPATH_BACKEND? == null) {
        if (which realpath | is-not-empty) {
            let test_result = (^realpath "/" | complete)
            if ($test_result.exit_code) == 0 and ($test_result.stdout | str trim) == "/" {
                $env.XDG_UTILS_REALPATH_BACKEND = "realpath"
            } else {
                # The realpath took the -- literally, probably the busybox implementation
                $env.XDG_UTILS_REALPATH_BACKEND = "busybox-realpath"
            }
        } else if (which readlink | is-not-empty) {
            $env.XDG_UTILS_REALPATH_BACKEND = "readlink"
        } else {
            exit_failure_operation_impossible "No usable realpath backend found"
        }
    }

    # Fail if file doesn't exist
    if not ($path | path exists) {
        return
    }

    match $env.XDG_UTILS_REALPATH_BACKEND {
        "realpath" => { ^realpath $path }
        "busybox-realpath" => { ^realpath (unoption_path $path) }
        "readlink" => { ^readlink -f (unoption_path $path) }
    }
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
