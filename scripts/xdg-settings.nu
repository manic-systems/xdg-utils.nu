#!/usr/bin/env nu
# xdg-settings - Get and set desktop environment settings

use xdg-utils-common.nu *

# Check if filename is valid desktop file
def --env check_desktop_filename [filename: string] {
    if ($filename | str contains "/") {
        exit_failure_syntax "invalid application name"
    }
    if not ($filename | str ends-with ".desktop") {
        exit_failure_syntax "invalid application name"
    }
}

# In order to remove an application from the automatically-generated list of
# applications for handling a given MIME type, the desktop environment may copy
# the global .desktop file into the user's .local directory, and remove that
# MIME type from its list. In that case, we must restore the MIME type to the
# application's list of MIME types before we can set it as the default for that
# MIME type. (We can't just delete the local version, since the user may have
# made other changes to it as well. So, tweak the existing file.)
# This function is hard-coded for text/html but it could be adapted if needed.
def --env fix_local_desktop_file [desktop_file: string, mimetype: string] {
    let mime = if ($mimetype | is-empty) { "text/html" } else { $mimetype }
    let apps_dir = ($env.XDG_DATA_HOME? | default ($env.HOME | path join ".local" "share") | path join "applications")
    let local_file = ($apps_dir | path join $desktop_file)

    if not (($local_file | path type) == "file") {
        return
    }

    let mimetypes_raw = (^grep "^MimeType=" $local_file | complete | get stdout | str trim)
    let mimetypes = if ($mimetypes_raw | str contains "=") {
        $mimetypes_raw | split row "=" | skip 1 | str join "="
    } else {
        ""
    }

    if ($mimetypes | str contains $mime) {
        return
    }

    let temp = (^mktemp $"($apps_dir)/($desktop_file).XXXXXX" | complete | get stdout | str trim)
    ^grep -v "^MimeType=" $local_file | save --force $temp
    let old_lines = (open --raw $local_file | lines | length)
    let new_lines = (open --raw $temp | lines | length)

    if $old_lines <= $new_lines {
        mv $temp $local_file
        sleep 4sec
    } else {
        rm --force $temp
    }
}

# xdg-mime may use ktradertest, which will fork off a copy of kdeinit if
# one does not already exist. It will exit after about 15 seconds if no
# further processes need it around. But since it does not close its stdout,
# the shell (via grep) will wait around for kdeinit to exit. If we start a
# copy here, that copy will be used in xdg-mime and we will avoid waiting.
def --env xdg_mime_fixup [] {
    if ($env.DE? == "kde") and ($env.XDG_MIME_FIXED? | default "" | is-empty) {
        ^ktradertest text/html Application o+e>| complete | ignore
        $env.XDG_MIME_FIXED = "yes"
    }
}

# Get browser MIME
def --env get_browser_mime [...mimetype: string] {
    let mime = if ($mimetype | is-empty) { "text/html" } else { $mimetype.0 }
    xdg_mime_fixup
    ^xdg-mime query default $mime | complete | get stdout | str trim
}

# Set browser MIME
def --env set_browser_mime [desktop_file: string, ...mimetype: string] {
    xdg_mime_fixup
    let mime = if ($mimetype | is-empty) { "text/html" } else { $mimetype.0 }
    let orig = (get_browser_mime $mime)
    # Fixing the local desktop file can actually change the default browser all
    # by itself, so we fix it only after querying to find the current default.
    fix_local_desktop_file $desktop_file $mime
    ^mkdir -p ($env.XDG_DATA_HOME? | default ($env.HOME | path join ".local" "share") | path join "applications")
    let result = (^xdg-mime default $desktop_file $mime | complete)
    if ($result.exit_code) != 0 {
        return
    }
    if (get_browser_mime $mime) != $desktop_file {
        ^xdg-mime default $orig $mime | complete
        exit_failure_operation_failed
    }
}

# Reads the KDE configuration setting, compensating for a bug in some versions of kreadconfig.
def --env read_kde_config [configfile: string, section: string, key: string] {
    let version = ($env.KDE_SESSION_VERSION? | default "" | into int)
    let kreadconfig = if $version == 5 {
        "kreadconfig5"
    } else if $version == 6 {
        "kreadconfig6"
    } else {
        "kreadconfig"
    }

    let result = (^$kreadconfig --file $configfile --group $section --key $key 2>/dev/null | complete | get stdout | str trim)
    if not ($result | is-empty) {
        print $result
        return
    }

    if $version == 4 {
        # kreadconfig in KDE 4 may not notice Key[$*]=... localized settings, so
        # check by hand if it didn't find anything (oddly kwriteconfig works
        # fine though).
        let config_dir = (^kde4-config --path config 2>/dev/null | complete | get stdout | split row ":" | get 0)
        let config_path = ($config_dir | path join $configfile)
        if ($config_path | path type) == "file" {
            let localized = (^grep $"^($key)\\[\\$[^]=]*\\]=" $config_path | complete | get stdout | ^head -n 1 | complete | get stdout | split row "=" | skip 1 | str join "=" | str trim)
            if not ($localized | is-empty) {
                print $localized
            }
        }
    }
}

# Resolves the KDE browser setting to a binary: if prefixed with !, simply removes it;
# otherwise, uses desktop_file_to_binary to get the binary out of the desktop file.
def --env resolve_kde_browser [browser: string] {
    if ($browser | is-empty) { return }
    if ($browser | str starts-with "!") {
        print ($browser | str replace --regex "^!" "")
    } else {
        desktop_file_to_binary $browser
    }
}

# Does the opposite of resolve_kde_browser: if prefixed with !, tries to find a desktop
# file corresponding to the binary, otherwise just returns the desktop file name.
def --env resolve_kde_browser_desktop [browser: string] {
    if ($browser | is-empty) { return }
    if ($browser | str starts-with "!") {
        let binary = ($browser | str replace --regex "^!" "")
        let desktop = (binary_to_desktop_file $binary)
        print ($desktop | path parse | get stem)
    } else {
        print $browser
    }
}

# Read KDE browser
def --env read_kde_browser [] {
    mut ret = (get_browser_mime "x-scheme-handler/http")
    if ($ret | is-empty) {
        $ret = (read_kde_config "kdeglobals" "General" "BrowserApplication")
    }
    print $ret
}

# Get browser on KDE
def --env get_browser_kde [] {
    let browser = (read_kde_browser | str trim)
    if ($browser | is-empty) {
        get_browser_mime
    } else {
        resolve_kde_browser_desktop $browser
    }
}

# Check browser on KDE
def --env check_browser_kde [desktop_file: string] {
    let check = (desktop_file_to_binary $desktop_file)
    if ($check | is-empty) {
        print "no"
        exit_success
    }
    let browser = (read_kde_browser)
    let binary = (resolve_kde_browser $browser)

    if ($browser | str starts-with "!") {
        let browser_path = (binary_to_desktop_file ($browser | str replace --regex "^!" ""))
        let _binary = (desktop_file_to_binary $browser_path)
    }

    # Because KDE will use the handler for MIME type text/html if this value
    # is empty, we allow either the empty string or a match to $check here.
    if not ($binary | is-empty) and ($binary != $check) {
        print "no"
        exit_success
    }

    let browser2 = (get_browser_mime)
    let binary2 = (desktop_file_to_binary $browser2)
    if ($binary2 != $check) {
        print "no"
        exit_success
    }

    print "yes"
    exit_success
}

# Set browser on KDE
def --env set_browser_kde [desktop_file: string] {
    for protocol in ["http", "https"] {
        set_browser_mime $desktop_file $"x-scheme-handler/($protocol)"
    }
    set_browser_mime $desktop_file "text/html"

    let version = ($env.KDE_SESSION_VERSION? | default "" | into int)
    let kwriteconfig = if $version == 5 {
        "kwriteconfig5"
    } else if $version == 6 {
        "kwriteconfig6"
    } else {
        "kwriteconfig"
    }

    let result = (^$kwriteconfig --file kdeglobals --group General --key BrowserApplication $desktop_file | complete)
}

# Read Deepin browser
def --env read_deepin_browser [] {
    let ret = (get_browser_mime "x-scheme-handler/http")
    if ($ret | is-empty) {
        let result = (^dbus-send --print-reply=literal --dest=com.deepin.daemon.Mime /com/deepin/daemon/Mime com.deepin.daemon.Mime.GetDefaultApp string:"x-scheme-handler/http" | complete)
        if ($result.exit_code) != 0 {
            exit_failure_operation_failed
        }
        # `--print-reply=literal` emits one quoted string per indented line.
        let id = ($result.stdout | parse --regex '"(?P<v>[^"]*)"' | get v? | get 0? | default "")
        print $id
        return
    }
    print $ret
}

# Get browser on Deepin
def --env get_browser_deepin [] {
    let browser = (read_deepin_browser)
    if not ($browser | is-empty) {
        print $browser
        exit_success
    }
    exit_failure_operation_failed
}

# Check browser on Deepin
def --env check_browser_deepin [desktop_file: string] {
    let current = (read_deepin_browser)
    if $current == $desktop_file {
        print "yes"
        exit_success
    }
    print "no"
    exit_failure_operation_failed
}

# Set browser on Deepin
def --env set_browser_deepin [desktop_file: string] {
    let result = (^xdg-mime default $desktop_file x-scheme-handler/http x-scheme-handler/ftp x-scheme-handler/https text/html text/xml text/xhtml_xml text/xhtml+xml | complete)
    if ($result.exit_code) != 0 {
        exit_failure_operation_failed
    }
    exit_success
}

# Get browser on GNOME
def --env get_browser_gnome [] {
    let binary = (^gconftool-2 --get /desktop/gnome/applications/browser/exec | complete | get stdout | str trim)
    if ($binary | is-empty) {
        get_browser_mime
    } else {
        # gconftool gives the binary (maybe with %s etc. afterward),
        # but we want the desktop file name, not the binary. So, we
        # have to find the desktop file to which it corresponds.
        let desktop = (binary_to_desktop_file $binary)
        print ($desktop | path parse | get stem)
    }
}

# Check browser on GNOME
def --env check_browser_gnome [desktop_file: string] {
    let check = (desktop_file_to_binary $desktop_file)
    if ($check | is-empty) {
        print "no"
        exit_success
    }
    let binary = (^gconftool-2 --get /desktop/gnome/applications/browser/exec | complete | get stdout | str trim)
    if ($binary != $check) {
        print "no"
        exit_success
    }
    for protocol in ["http", "https"] {
        let binary = (^gconftool-2 --get $"/desktop/gnome/url-handlers/($protocol)/command" | complete | get stdout | str trim)
        if ($binary != $check) {
            print "no"
            exit_success
        }
    }
    let browser = (get_browser_mime)
    let binary = (desktop_file_to_binary $browser)
    if ($binary != $check) {
        print "no"
        exit_success
    }
    print "yes"
    exit_success
}

# Set browser on GNOME
def --env set_browser_gnome [desktop_file: string] {
    let binary = (desktop_file_to_binary $desktop_file)
    if ($binary | is-empty) {
        exit_failure_file_missing
    }
    set_browser_mime $desktop_file

    let result = (^gconftool-2 --type string --set /desktop/gnome/applications/browser/exec $binary | complete)
    let result = (^gconftool-2 --type bool --set /desktop/gnome/applications/browser/needs_term false | complete)
    let result = (^gconftool-2 --type bool --set /desktop/gnome/applications/browser/nremote true | complete)
    for protocol in ["http", "https", "about", "unknown"] {
        let result = (^gconftool-2 --type string --set $"/desktop/gnome/url-handlers/($protocol)/command" $"($binary) %s" | complete)
        let result = (^gconftool-2 --type bool --set $"/desktop/gnome/url-handlers/($protocol)/needs_terminal" false | complete)
        let result = (^gconftool-2 --type bool --set $"/desktop/gnome/url-handlers/($protocol)/enabled" true | complete)
    }
}

# Get browser on GNOME 3.x
def --env get_browser_gnome3 [] {
    get_browser_mime "x-scheme-handler/http"
}

# Check browser on GNOME 3.x
def --env check_browser_gnome3 [desktop_file: string] {
    let check = (desktop_file_to_binary $desktop_file)
    if ($check | is-empty) {
        print "no"
        exit_success
    }
    for protocol in ["http", "https"] {
        let browser = (get_browser_mime $"x-scheme-handler/($protocol)")
        if ($browser != $desktop_file) {
            print "no"
            exit_success
        }
    }
    print "yes"
    exit_success
}

# Set browser on GNOME 3.x
def --env set_browser_gnome3 [desktop_file: string] {
    let binary = (desktop_file_to_binary $desktop_file)
    if ($binary | is-empty) {
        exit_failure_file_missing
    }
    set_browser_mime $desktop_file
    for protocol in ["http", "https", "about", "unknown"] {
        set_browser_mime $desktop_file $"x-scheme-handler/($protocol)"
    }
}

# Get browser on LXQt
def --env get_browser_lxqt [] {
    if (^qtxdg-mat def-web-browser --help 2>/dev/null | complete | get exit_code) == 0 {
        let result = (^qtxdg-mat def-web-browser 2>/dev/null | complete | get stdout)
        print ($result | str trim)
        exit_success
    }
    exit_failure_operation_impossible "no method for getting the default browser"
}

# Check browser on LXQt
def --env check_browser_lxqt [desktop_file: string] {
    let check = (desktop_file_to_binary $desktop_file)
    if ($check | is-empty) {
        print "no"
        exit_success
    }
    if (^qtxdg-mat def-web-browser --help 2>/dev/null | complete | get exit_code) == 0 {
        let browser = (^qtxdg-mat def-web-browser 2>/dev/null | complete | get stdout)
        if ($browser != $desktop_file) {
            print "no"
            exit_success
        }
    } else {
        exit_failure_operation_impossible "no method for checking the default browser"
    }
}

# Set browser on LXQt
def --env set_browser_lxqt [desktop_file: string] {
    let binary = (desktop_file_to_binary $desktop_file)
    if ($binary | is-empty) {
        exit_failure_file_missing
    }
    set_browser_mime $desktop_file
    for protocol in ["http", "https", "about", "unknown"] {
        set_browser_mime $desktop_file $"x-scheme-handler/($protocol)"
    }
}

# Get browser on XFCE
def --env get_browser_xfce [] {
    let xdg_config = (get_xdg_config_home)
    let search = $"($xdg_config):/etc/xdg"
    let search_dirs = ($search | split row ":")
    for dir in $search_dirs {
        let file = ($dir | path join "xfce4" "helpers.rc")
        if ($file | path type) == "file" {
            let webbrowser_raw = (^grep "^WebBrowser=" $file | complete | get stdout | str trim)
            let webbrowser = if ($webbrowser_raw | str contains "=") {
                $webbrowser_raw | split row "=" | skip 1 | str join "=" | str trim
            } else {
                ""
            }
            if not ($webbrowser | is-empty) {
                print $"($webbrowser).desktop"
                exit_success
            }
        }
    }
    exit_failure_operation_failed
}

# Check browser on XFCE
def --env check_browser_xfce [desktop_file: string] {
    let browser = (get_browser_xfce)
    if ($browser != $desktop_file) {
        print "no"
        exit_success
    }
    print "yes"
    exit_success
}

# Set browser on XFCE
def --env set_browser_xfce [desktop_file: string] {
    let helper_dir = ((get_xdg_config_home) | path join "xfce4")
    ^mkdir -p $helper_dir
    let helpers_rc = ($helper_dir | path join "helpers.rc")
    if ($helpers_rc | path type) != "file" {
        touch $helpers_rc
    }

    let temp = (^mktemp $"($helpers_rc).XXXXXX" | complete | get stdout | str trim)
    ^grep -v "^WebBrowser=" $helpers_rc | save --force $temp
    # Atomically swap the filtered temp file in for the live helpers.rc.
    ^mv $temp $helpers_rc
    print --stderr "Setting browser to xfce4-web-browser.desktop to make setting effective ..."
    set_browser_generic "xfce4-web-browser.desktop"
}

# Get browser generically
def --env get_browser_generic [mimetype: string] {
    let mime = if ($mimetype | is-empty) { "x-scheme-handler/http" } else { $mimetype }
    let result = (get_browser_mime $mime)
    if not ($result | is-empty) {
        print $result
        return
    }

    if not ($env.BROWSER? | default "" | is-empty) {
        let browser = (binary_to_desktop_file ($env.BROWSER | split row ":" | get 0))
        if not ($browser | is-empty) {
            print ($browser | path parse | get stem)
            return
        }
    }

    # Debian and derivatives have x-www-browser
    let browser = (binary_to_desktop_file "x-www-browser")
    if not ($browser | is-empty) {
        print ($browser | path parse | get stem)
        return
    }
}

# Check browser generically
def --env check_browser_generic [desktop_file: string] {
    if ($desktop_file != (get_browser_generic "x-scheme-handler/http")) {
        print "no"
        exit_success
    }
    if ($desktop_file != (get_browser_mime)) {
        print "no"
        exit_success
    }
    print "yes"
    exit_success
}

# Normalize binary path
def --env normalize_binary [binary: string] {
    xdg_realpath (which $binary | get path.0? | default "")
}

# The BROWSER variable is outside the control of xdg-settings,
# the best we can do is to do our part and explain
# that additional configuration could be necessary
#
# Takes as argument the value browser is suggested to be set to.
def --env explain_browser_variable [expected: string] {
    let norm_expected = (normalize_binary $expected)
    let norm_browser = (normalize_binary ($env.BROWSER? | default ""))
    if $norm_expected != $norm_browser {
        print --stderr "$BROWSER is set and can't be changed with xdg-settings."
        print --stderr "This means that some applications won't adopt the new browser setting."
        print --stderr "$BROWSER envoirnment variable is likely set in your ~/.profile or ~/.bashrc which you have to edit manually."
        print --stderr ""
        print --stderr $"Your $BROWSER is currently set to: ($env.BROWSER? | default '')"
        print --stderr $"It should be set to: ($expected)"
    }
}

# Set browser generically
def --env set_browser_generic [desktop_file: string] {
    let binary = (desktop_file_to_binary $desktop_file)
    if ($binary | is-empty) {
        exit_failure_file_missing "Can't resolve this desktop file name to a command"
    }

    if not ($env.BROWSER? | default "" | is-empty) and ($binary != ($env.BROWSER? | default "")) {
        explain_browser_variable $binary
    }

    set_browser_mime $desktop_file "text/html"
    for protocol in ["http", "https", "about", "unknown"] {
        set_browser_mime $desktop_file $"x-scheme-handler/($protocol)"
    }
}

# URL scheme handler for KDE
def --env get_url_scheme_handler_kde [scheme: string] {
    if $scheme == "mailto" {
        let handler = (read_kde_config "emaildefaults" "PROFILE_Default" "EmailClient" | str trim)
        if not ($handler | is-empty) {
            let desktop = (binary_to_desktop_file $handler)
            print $desktop
            return
        }
    }
    get_browser_mime $"x-scheme-handler/($scheme)"
}

# Check URL scheme handler for KDE
def --env check_url_scheme_handler_kde [scheme: string, desktop_file: string] {
    let check = (desktop_file_to_binary $desktop_file)
    if ($check | is-empty) {
        print "no"
        exit_success
    }
    if $scheme == "mailto" {
        let binary = (read_kde_config "emaildefaults" "PROFILE_Default" "EmailClient")
        if ($binary | str starts-with "!") {
            let desktop = (binary_to_desktop_file ($binary | str replace --regex "^!" ""))
            let _binary = (desktop_file_to_binary $desktop)
        }
        if ($binary != $check) {
            print "no"
            exit_success
        }
    } else {
        let handler = (get_browser_mime $"x-scheme-handler/($scheme)")
        let binary = (desktop_file_to_binary $handler)
        if ($binary != $check) {
            print "no"
            exit_success
        }
    }
    print "yes"
    exit_success
}

# Set URL scheme handler for KDE
def --env set_url_scheme_handler_kde [scheme: string, desktop_file: string] {
    set_browser_mime $desktop_file $"x-scheme-handler/($scheme)"
    if $scheme == "mailto" {
        let binary = (desktop_file_to_binary $desktop_file)
        let version = ($env.KDE_SESSION_VERSION? | default "" | into int)
        let kwriteconfig = if $version == 5 {
            "kwriteconfig5"
        } else if $version == 6 {
            "kwriteconfig6"
        } else {
            "kwriteconfig"
        }
        let result = (^$kwriteconfig --file emaildefaults --group PROFILE_Default --key EmailClient $binary | complete)
    }
}

# Get URL scheme handler for GNOME
def --env get_url_scheme_handler_gnome [scheme: string] {
    let binary = (^gconftool-2 --get $"/desktop/gnome/url-handlers/($scheme)/command" | complete | get stdout | str trim)
    if not ($binary | is-empty) {
        let desktop = (binary_to_desktop_file $binary)
        print ($desktop | path parse | get stem)
    }
}

# Check URL scheme handler for GNOME
def --env check_url_scheme_handler_gnome [scheme: string, desktop_file: string] {
    let check = (desktop_file_to_binary $desktop_file)
    if ($check | is-empty) {
        print "no"
        exit_success
    }
    let binary = (^gconftool-2 --get $"/desktop/gnome/url-handlers/($scheme)/command" | complete | get stdout | str trim)
    if ($binary != $check) {
        print "no"
        exit_success
    }
    print "yes"
    exit_success
}

# Set URL scheme handler for GNOME
def --env set_url_scheme_handler_gnome [scheme: string, desktop_file: string] {
    let binary = (desktop_file_to_binary $desktop_file)
    if ($binary | is-empty) {
        exit_failure_file_missing
    }
    let result = (^gconftool-2 --type string --set $"/desktop/gnome/url-handlers/($scheme)/command" $"($binary) %s" | complete)
    let result = (^gconftool-2 --type bool --set $"/desktop/gnome/url-handlers/($scheme)/needs_terminal" false | complete)
    let result = (^gconftool-2 --type bool --set $"/desktop/gnome/url-handlers/($scheme)/enabled" true | complete)
}

# Get URL scheme handler for LXQt
def --env get_url_scheme_handler_lxqt [scheme: string] {
    if (^qtxdg-mat defapp --help 2>/dev/null | complete | get exit_code) == 0 {
        let result = (^qtxdg-mat defapp $"x-scheme-handler/($scheme)" 2>/dev/null | complete | get stdout)
        print ($result | str trim)
        exit_success
    }
    exit_failure_operation_impossible "no method for getting the url_scheme_handler"
}

# Check URL scheme handler for LXQt
def --env check_url_scheme_handler_lxqt [scheme: string, desktop_file: string] {
    let check = (desktop_file_to_binary $desktop_file)
    if ($check | is-empty) {
        print "no"
        exit_success
    }
    if (^qtxdg-mat defapp --help 2>/dev/null | complete | get exit_code) == 0 {
        let handler = (^qtxdg-mat defapp $"x-scheme-handler/($scheme)" 2>/dev/null | complete | get stdout)
        if ($handler != $desktop_file) {
            print "no"
            exit_success
        }
    } else {
        exit_failure_operation_impossible $"no method for checking the url_scheme_handler for desktop ($env.DE? | default '')"
    }
}

# Set URL scheme handler for LXQt
def --env set_url_scheme_handler_lxqt [scheme: string, desktop_file: string] {
    let binary = (desktop_file_to_binary $desktop_file)
    if ($binary | is-empty) {
        exit_failure_file_missing
    }
    set_browser_mime $desktop_file $"x-scheme-handler/($scheme)"
}

# Get URL scheme handler for GNOME 3.x
def --env get_url_scheme_handler_gnome3 [scheme: string] {
    get_browser_mime $"x-scheme-handler/($scheme)"
}

# Check URL scheme handler for GNOME 3.x
def --env check_url_scheme_handler_gnome3 [scheme: string, desktop_file: string] {
    let check = (desktop_file_to_binary $desktop_file)
    if ($check | is-empty) {
        print "no"
        exit_success
    }
    let browser = (get_browser_mime $"x-scheme-handler/($scheme)")
    if ($browser != $desktop_file) {
        print "no"
        exit_success
    }
    print "yes"
    exit_success
}

# Set URL scheme handler for GNOME 3.x
def --env set_url_scheme_handler_gnome3 [scheme: string, desktop_file: string] {
    let binary = (desktop_file_to_binary $desktop_file)
    if ($binary | is-empty) {
        exit_failure_file_missing
    }
    set_browser_mime $desktop_file $"x-scheme-handler/($scheme)"
}

# Get URL scheme handler generically
def --env get_url_scheme_handler_generic [scheme: string] {
    if not ($env.BROWSER? | default "" | is-empty) and (($scheme == "http") or ($scheme == "https")) {
        get_browser_generic $"x-scheme-handler/($scheme)"
    } else {
        get_browser_mime $"x-scheme-handler/($scheme)"
    }
}

# Check URL scheme handler generically
def --env check_url_scheme_handler_generic [scheme: string, desktop_file: string] {
    let check = (desktop_file_to_binary $desktop_file)
    if ($check | is-empty) {
        print "no"
        exit_success
    }
    let browser = (get_url_scheme_handler_generic $scheme)
    if ($browser != $desktop_file) {
        print "no"
        exit_success
    }
    print "yes"
    exit_success
}

# Set URL scheme handler generically
def --env set_url_scheme_handler_generic [scheme: string, desktop_file: string] {
    let binary = (desktop_file_to_binary $desktop_file)
    if ($binary | is-empty) {
        exit_failure_file_missing "Can't resolve a command for the given desktop file name"
    }
    if not ($env.BROWSER? | default "" | is-empty) and (($scheme == "http") or ($scheme == "https")) {
        explain_browser_variable $binary
    }
    set_browser_mime $desktop_file $"x-scheme-handler/($scheme)"
}

# {{{ default url scheme handler

# Recent versions of KDE support default scheme handler applications using the
# mime type of x-scheme-handler/scheme. Older versions will not support this
# but do have support for setting a default mail handler. There is also a
# system in KDE where .protocol files can be used, however this is not
# supported by this script. When reading a scheme handler we will use the
# default mail handler for the mailto scheme, otherwise we will use the mime
# type x-scheme-handler/scheme.

# Dispatches the given cli command to the correct handler
# Expects global variables:
# * op: "get", "check" or "set"
# * parm: "default-web-browser" or "default-url-scheme-handler"
def --env dispatch_specific [handler: string, op: string, parm: string, ...rest] {
    # The PROP comments in this function are used to generate the output of
    # the --list option. The formatting is important. Make sure to line up the
    # property descriptions with spaces so that it will look nice.
    match $op {
        "get" => {
            match $parm {
                "default-web-browser" => {
                    match $handler {
                        "kde" => { get_browser_kde }
                        "gnome" => { get_browser_gnome }
                        "gnome3" => { get_browser_gnome3 }
                        "lxqt" => { get_browser_lxqt }
                        "xfce" => { get_browser_xfce }
                        _ => { get_browser_generic "x-scheme-handler/http" }
                    }
                }
                "default-url-scheme-handler" => {
                    let scheme = ($rest | get 0)
                    match $handler {
                        "kde" => { get_url_scheme_handler_kde $scheme }
                        "gnome" => { get_url_scheme_handler_gnome $scheme }
                        "gnome3" => { get_url_scheme_handler_gnome3 $scheme }
                        "lxqt" => { get_url_scheme_handler_lxqt $scheme }
                        "xfce" => { get_url_scheme_handler_xfce $scheme }
                        _ => { get_url_scheme_handler_generic $scheme }
                    }
                }
            }
        }
        "check" => {
            match $parm {
                "default-web-browser" => {
                    check_desktop_filename ($rest | get 0)
                    match $handler {
                        "kde" => { check_browser_kde ($rest | get 0) }
                        "gnome" => { check_browser_gnome ($rest | get 0) }
                        "gnome3" => { check_browser_gnome3 ($rest | get 0) }
                        "lxqt" => { check_browser_lxqt ($rest | get 0) }
                        "xfce" => { check_browser_xfce ($rest | get 0) }
                        _ => { check_browser_generic ($rest | get 0) }
                    }
                }
                "default-url-scheme-handler" => {
                    let scheme = ($rest | get 0)
                    let desktop = ($rest | get 1)
                    check_desktop_filename $desktop
                    match $handler {
                        "kde" => { check_url_scheme_handler_kde $scheme $desktop }
                        "gnome" => { check_url_scheme_handler_gnome $scheme $desktop }
                        "gnome3" => { check_url_scheme_handler_gnome3 $scheme $desktop }
                        "lxqt" => { check_url_scheme_handler_lxqt $scheme $desktop }
                        "xfce" => { check_url_scheme_handler_xfce $scheme $desktop }
                        _ => { check_url_scheme_handler_generic $scheme $desktop }
                    }
                }
            }
        }
        "set" => {
            match $parm {
                "default-web-browser" => {
                    if (($rest | length) != 1) {
                        exit_failure_syntax "unexpected/missing argument"
                    }
                    let desktop_file = ($rest | get 0)
                    check_desktop_filename $desktop_file
                    match $handler {
                        "kde" => { set_browser_kde $desktop_file }
                        "gnome" => { set_browser_gnome $desktop_file }
                        "gnome3" => { set_browser_gnome3 $desktop_file }
                        "lxqt" => { set_browser_lxqt $desktop_file }
                        "xfce" => { set_browser_xfce $desktop_file }
                        _ => { set_browser_mime $desktop_file "x-scheme-handler/http" }
                    }
                }
                "default-url-scheme-handler" => {
                    if (($rest | length) != 2) {
                        exit_failure_syntax "unexpected/missing argument"
                    }
                    let scheme = ($rest | get 0)
                    let desktop_file = ($rest | get 1)
                    check_desktop_filename $desktop_file
                    match $handler {
                        "kde" => { set_url_scheme_handler_kde $scheme $desktop_file }
                        "gnome" => { set_url_scheme_handler_gnome $scheme $desktop_file }
                        "gnome3" => { set_url_scheme_handler_gnome3 $scheme $desktop_file }
                        "lxqt" => { set_url_scheme_handler_lxqt $scheme $desktop_file }
                        "xfce" => { set_url_scheme_handler_xfce $scheme $desktop_file }
                        _ => { set_url_scheme_handler_generic $scheme $desktop_file }
                    }
                }
            }
        }
    }
}

# xdg-settings - get various settings from the desktop environment
# Synopsis: xdg-settings { get | check | set } {property} [subproperty] [value]
# Synopsis: xdg-settings { --help | --list | --manual | --version }
def --wrapped main [...args] {
    let args = ($args | each { into string })
    handle_standard_options "xdg-settings" $args [
        "xdg-settings - get various settings from the desktop environment"
        ""
        "Synopsis"
        ""
        "xdg-settings { get | check | set } {property} [subproperty] [value]"
        ""
        "xdg-settings { --help | --list | --manual | --version }"
    ]

    if not ($args | is-empty) and (($args | get 0) == "--list") {
        print "Known properties:"
        print "  default-web-browser           Default web browser"
        print "  default-url-scheme-handler   Default handler for URL scheme"
        exit_success
    }

    if ($args | is-empty) {
        exit_failure_syntax "no operation given"
    }
    if (($args | length) < 2) {
        exit_failure_syntax "no parameter name given"
    }

    let op = ($args | get 0)
    let parm = ($args | get 1)
    let rest = ($args | skip 2)

    if not (($op == "get") or ($op == "check") or ($op == "set")) {
        exit_failure_syntax "invalid operation"
    }

    if ($op != "get") and (($rest | is-empty)) {
        exit_failure_syntax "no parameter value given"
    }

    detectDE
    if ($env.DE? | default "" | is-empty) {
        $env.DE = "generic"
    }

    match $env.DE {
        "kde" => { dispatch_specific "kde" $op $parm ...$rest }
        "deepin" => { dispatch_specific "deepin" $op $parm ...$rest }
        "gnome" => { dispatch_specific "gnome" $op $parm ...$rest }
        "gnome3" => { dispatch_specific "gnome3" $op $parm ...$rest }
        "cinnamon" => { dispatch_specific "gnome3" $op $parm ...$rest }
        "lxde" => { dispatch_specific "gnome3" $op $parm ...$rest }
        "mate" => { dispatch_specific "gnome3" $op $parm ...$rest }
        "budgie" => { dispatch_specific "gnome3" $op $parm ...$rest }
        "lxqt" => { dispatch_specific "lxqt" $op $parm ...$rest }
        "xfce" => { dispatch_specific "xfce" $op $parm ...$rest }
        "generic" => { dispatch_specific "generic" $op $parm ...$rest }
        "enlightenment" => { dispatch_specific "generic" $op $parm ...$rest }
    }

    exit_failure_operation_impossible "unknown desktop environment"
}
