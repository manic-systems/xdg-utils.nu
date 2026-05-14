#!/usr/bin/env nu
# xdg-mime - Utility to manipulate MIME related information

use xdg-utils-common.nu *

# Update KDE cache
def --env update_kde_cache [] {
    DEBUG 1 "Running kbuildsycoca"
    let version = ($env.KDE_SESSION_VERSION? | default "0" | into int)
    if $version > 3 {
        let cmd = $"kbuildsycoca($env.KDE_SESSION_VERSION? | default '')"
        ^$cmd | complete | ignore
    } else {
        ^kbuildsycoca | complete | ignore
    }
}

# Update MIME database
def --env update_mime_database [mode: string] {
    if $mode == "user" and (has_display) {
        detectDE
        if $env.DE == "kde" {
            update_kde_cache
        }
    }

    for dir in (($env.PATH | split row ":") | append "/opt/gnome/bin") {
        let updater = ($dir | path join "update-mime-database")
        if (is-executable $updater) {
            DEBUG 1 $"Running ($updater)"
            ^$updater | complete | ignore
            return
        }
    }
}

# info_* functions that print the mimetype of a given file

# Query MIME type using KDE
def --env info_kde [filename: string] {
    let version = ($env.KDE_SESSION_VERSION? | default "")
    if ($version | is-empty) {
        let result = (^kfile $filename | complete)
        let parsed = ($result.stdout | split row "(" | get 1? | default "" | split row ")" | get 0? | default "")
        if not ($parsed | is-empty) {
            print $parsed
            exit_success
        }
    } else {
        let tool = if $version == "5" { "kmimetypefinder5" } else { "kmimetypefinder" }
        let result = (^$tool $filename | complete)
        if ($result.exit_code) == 0 {
            print (($result.stdout) | lines | where { ($in | is-not-empty) } | get 0? | default "")
            exit_success
        }
    }
    exit_failure_operation_failed
}

# Query MIME type using GNOME
def --env info_gnome [filename: string] {
    let result = if (^gio help info | complete).exit_code == 0 {
        (^gio info $filename | complete | get stdout)
    } else if (^gvfs-info --help | complete).exit_code == 0 {
        (^gvfs-info $filename | complete | get stdout)
    } else if (^gnomevfs-info --help | complete).exit_code == 0 {
        (^gnomevfs-info --slow-mime $filename | complete | get stdout)
    } else {
        exit_failure_operation_impossible $"no method available for querying MIME type of '($filename)'"
        ""
    }

    let mimetype = ($result | ^grep "standard::content-type" | complete | get stdout | split row " " | get 3? | default "")
    if not ($mimetype | is-empty) {
        print $mimetype
        exit_success
    }
    exit_failure_operation_failed
}

# Query MIME type using LXQt
def --env info_lxqt [filename: string] {
    if (^qtxdg-mat mimetype --help | complete).exit_code == 0 {
        let result = (^qtxdg-mat mimetype $filename | complete)
        if ($result.exit_code) == 0 {
            print (($result.stdout) | str trim)
            exit_success
        }
    }
    exit_failure_operation_impossible $"no method available for querying MIME type of '($filename)'"
}

# Query MIME type generically
def --env info_generic [filename: string] {
    let result = if (which mimetype | is-not-empty) {
        (^mimetype --brief --dereference $filename | complete)
    } else if (which file | is-not-empty) {
        (^file --brief --dereference --mime-type $filename | complete)
    } else {
        exit_failure_operation_impossible $"no method available for querying MIME type of '($filename)'"
    }

    if ($result.exit_code) == 0 {
        print (($result.stdout) | str trim)
        exit_success
    }
    exit_failure_operation_failed
}

# make_default_* functions that set a given desktop file as the handler for a given mimetype

# Set default application using KDE
def --env make_default_kde [desktop_file: string, mimetype: string] {
    # $1 is vendor-name.desktop
    # $2 is mime/type
    #
    # On KDE 3, add to $KDE_CONFIG_PATH/profilerc:
    # [$2 - 1]
    # Application=$1
    #
    # Remove all [$2 - *] sections, or even better,
    # renumber [$2 - *] sections and remove duplicate
    #
    # On KDE 4, add $2=$1 to $XDG_DATA_APPS/mimeapps.list
    #
    # Example file:
    #
    # [Added Associations]
    # text/plain=kde4-kate.desktop;kde4-kwrite.desktop;
    #
    let vendor = $desktop_file
    let version = ($env.KDE_SESSION_VERSION? | default "0" | into int)

    let default_dir = if $version > 4 {
        get_xdg_config_home
    } else if ($env.KDE_SESSION_VERSION? | default "") == "4" {
        if (which kde4-config | is-empty) { "" } else {
            let result = (^kde4-config --path xdgdata-apps | complete)
            if ($result.exit_code) == 0 { (($result.stdout) | split row ":" | get 0) } else { "" }
        }
    } else if (which kde-config | is-not-empty) {
        let result = (^kde-config --path config | complete)
        if ($result.exit_code) == 0 { (($result.stdout) | split row ":" | get 0) } else { "" }
    } else {
        ""
    }

    if ($default_dir | is-empty) {
        DEBUG 2 "make_default_kde: No kde runtime detected"
        return
    }

    let default_file = ($default_dir | path join "mimeapps.list")
    ^mkdir -p ($default_dir | path dirname)
    if not ($default_file | path type) == "file" {
        ^touch $default_file
    }

    if $version > 3 {
        # KDE 4+ logic using awk
        let awk_script = '
BEGIN { prefix=mimetype "="; associations=0; found=0; blanks=0 }
{
    suppress=0
    if (index($0, "[Added Associations]") == 1) {
        associations=1
    } else if (index($0, "[") == 1) {
        if (associations && !found) {
            print prefix application
            found=1
        }
        associations=0
    } else if ($0 == "") {
        blanks++
        suppress=1
    } else if (associations && index($0, prefix) == 1) {
        value=substr($0, length(prefix) + 1, length())
        split(value, apps, ";")
        value=application ";"
        count=0
        for (i in apps) { count++ }
        for (i=0; i < count; i++) {
            if (apps[i] != application && apps[i] != "") {
                value=value apps[i] ";"
            }
        }
        $0=prefix value
        found=1
    }
    if (!suppress) {
        while (blanks > 0) { print ""; blanks-- }
        print $0
    }
}
END {
    if (!found) {
        if (!associations) { print "[Added Associations]" }
        print prefix application
    }
    while (blanks > 0) { print ""; blanks-- }
}'
        let new_file = $"($default_file).new"
        ^awk $"-v application=($vendor)" $"-v mimetype=($mimetype)" $awk_script $default_file | save --force $new_file
        ^mv $new_file $default_file
    }
}

# Set default application using LXQt
def --env make_default_lxqt [desktop_file: string, mimetype: string] {
    if (^qtxdg-mat defapp --help | complete).exit_code == 0 {
        let result = (^qtxdg-mat defapp --set $desktop_file $mimetype | complete)
        if ($result.exit_code) == 0 {
            exit_success
        }
    }
    exit_failure_operation_impossible $"no method available for setting the default application for MIME type(s) of '($mimetype)'"
}

# Set default application generically
def --env make_default_generic [desktop_file: string, mimetype: string] {
    let default_file = ((get_xdg_config_home) | path join "mimeapps.list")
    let out_file = if ($default_file | path type) == "symlink" {
        xdg_realpath $default_file
    } else {
        $default_file
    }
    DEBUG 2 $"make_default_generic ($desktop_file) ($mimetype)"
    DEBUG 1 $"Updating ($out_file)"
    if not ($out_file | path type) == "file" {
        ^touch $out_file
    }

    let awk_script = '
BEGIN { prefix=mimetype "="; indefault=0; added=0; blanks=0; found=0 }
{
    suppress=0
    if (index($0, "[Default Applications]") == 1) {
        indefault=1
        found=1
    } else if (index($0, "[") == 1) {
        if (!added && indefault) {
            print prefix application
            added=1
        }
        indefault=0
    } else if ($0 == "") {
        suppress=1
        blanks++
    } else if (indefault && !added && index($0, prefix) == 1) {
        $0=prefix application
        added=1
    }
    if (!suppress) {
        while (blanks > 0) { print ""; blanks-- }
        print $0
    }
}
END {
    if (!added) {
        if (!found) { print ""; print "[Default Applications]" }
        print prefix application
    }
    while (blanks > 0) { print ""; blanks-- }
}
'
    let new_file = $"($out_file).new"
    ^awk $"-v mimetype=($mimetype)" $"-v application=($desktop_file)" $awk_script $out_file | save --force $new_file
    ^mv $new_file $out_file
}

# Extract MIME types from XML file using awk
def --env extract_mimetypes_from_xml [filename: string] {
    let strip_comments_awk = '
BEGIN { suppress=0 }
{
    do {
        if (suppress) {
            if (match($0,/-->/)) {
                $0=substr($0,RSTART+RLENGTH)
                suppress=0
            } else {
                break
            }
        } else {
            if (match($0,/<!--/)) {
                if (RSTART>1) print substr($0,0,RSTART)
                $0=substr($0,RSTART+RLENGTH)
                suppress=1
            } else {
                if ($0) print $0
                break
            }
        }
    } while(1)
}
'
    let extract_types_awk = '
BEGIN { RS="<" }
/^mime-info/, /^\/mime-info/ {
    if (match($0,/^mime-type/)) {
        if (match($0,/type="[^"]*/) || match($0,/type=.[^'\''']*/)) {
            print substr($0,RSTART+6,RLENGTH-6)
        }
    }
}
'
    let result = (^awk $strip_comments_awk $filename | ^awk $extract_types_awk | complete)
    if ($result.exit_code) == 0 {
        return (($result.stdout) | lines | where { not ($it | is-empty) })
    }
    return []
}

# Create KDE desktop file from XML for a specific MIME type
def --env create_kde_desktop_from_xml [filename: string, mimetype: string, kde_dir: string] {
    let basefile = ($filename | path basename)
    let desktop_file = ($kde_dir | path join $"($mimetype).desktop")

    let strip_comments_awk = '
BEGIN { suppress=0 }
{
    do {
        if (suppress) {
            if (match($0,/-->/)) {
                $0=substr($0,RSTART+RLENGTH)
                suppress=0
            } else {
                break
            }
        } else {
            if (match($0,/<!--/)) {
                if (RSTART>1) print substr($0,0,RSTART)
                $0=substr($0,RSTART+RLENGTH)
                suppress=1
            } else {
                if ($0) print $0
                break
            }
        }
    } while(1)
}
'

    let extract_mimetype_awk = '
# Extract mimetype from the XML file
BEGIN {
    the_type=ARGV[1]
    ARGC=1
    RS="<"
    found=0
    glob_patterns=""
}
/^mime-info/, /^\/mime-info/ {
    if (match($0,/^mime-type/)) {
        if (match($0,/type="[^"]*/) || match($0,/type=.[^'\''']*/)) {
            if (substr($0,RSTART+6,RLENGTH-6) == the_type) {
                found=1
                print "[Desktop Entry]"
                print "# Installed by xdg-mime from " the_source
                print "Type=MimeType"
                print "MimeType=" the_type
                the_icon=the_type
                gsub("/", "-", the_icon)
                print "Icon=" the_icon
            }
        }
    } else if (found) {
        if (match($0,/^\/mime-type/)) {
            if (glob_patterns)
                print "Patterns=" glob_patterns
            exit 0
        }
        if (match($0,/^sub-class-of/)) {
            if (match($0,/type="[^"]*/) || match($0,/type=.[^'\''']*/)) {
                print "X-KDE-IsAlso=" substr($0,RSTART+6,RLENGTH-6)
            } else {
                print "Error: '\''type'\'' argument missing in " RS $0
                exit 1
            }
        }
        if (match($0,/^glob/)) {
            if (match($0,/pattern="[^"]*/) || match($0,/pattern=.[^'\''']*/)) {
                glob_patterns = glob_patterns substr($0,RSTART+9,RLENGTH-9) ";"
            } else {
                print "Error: '\''pattern'\'' argument missing in " RS $0
                exit 1
            }
        }
        if (match($0,/^comment/)) {
            if (match($0,/xml:lang="[^"]*/) || match($0,/xml:lang=.[^'\''']*/)) {
                lang=substr($0,RSTART+10,RLENGTH-10)
            } else {
                lang=""
            }
            if (match($0,/>/)) {
                comment=substr($0,RSTART+1)
                gsub("&lt;", "<", comment)
                gsub("&gt;", ">", comment)
                gsub("&amp;", "\\&", comment)
                if (lang)
                    print "Comment[" lang "]=" comment
                else
                    print "Comment=" comment
            }
        }
    }
}
END {
    if (!found) {
        print "Error: mimetype '\''" the_type "'\'' not found"
        exit 1
    }
}
'

    mkdir ($desktop_file | path dirname)
    let new_file = $"($desktop_file).new"
    let result = (^awk $strip_comments_awk $filename | ^awk $"-v" $"the_type=($mimetype)" $"-v" $"the_source=($basefile)" $extract_mimetype_awk | complete)

    if ($result.exit_code) != 0 {
        if (($result.stdout) | str contains "Error:") {
            print ($result.stdout)
            error make { msg: "ERROR" }
        }
        return false
    }
    $result.stdout | save --force $new_file
    ^mv $new_file $desktop_file
    return true
}

# Install mimetypes from XML file
def --env install_mimetypes [filename: string, mode: string] {
    let xdg_dir_name = "mime/packages/"

    # Determine user directory
    let xdg_user_dir = if not ($env.XDG_DATA_HOME? == null) { $env.XDG_DATA_HOME } else { $env.HOME | path join ".local" "share" }
    let xdg_user_dir = ($xdg_user_dir | path join $xdg_dir_name)

    # Determine system directories
    let xdg_system_dirs = if not ($env.XDG_DATA_DIRS? == null) { $env.XDG_DATA_DIRS } else { "/usr/local/share/:/usr/share/" }

    # Find writable system directory
    mut xdg_base_dir = ""
    mut xdg_global_dir = ""
    for x in ($xdg_system_dirs | split row ":") {
        if ($x | is-empty) { continue }
        let test_dir = ($x | path join $xdg_dir_name)
        if (($test_dir | path type) == "dir" and (is-writable $test_dir)) {
            if $mode == "system" {
                $xdg_base_dir = ($x | path join "mime")
            }
            $xdg_global_dir = $test_dir
            break
        }
    }

    DEBUG 3 $"xdg_user_dir: ($xdg_user_dir)"
    DEBUG 3 $"xdg_global_dir: ($xdg_global_dir)"

    # Find KDE3 mimelnk directory
    mut kde_user_dir = ""
    mut kde_global_dir = ""
    if not ($env.KDE_SESSION_VERSION? == null) {
        let kde_config_cmd = $"kde($env.KDE_SESSION_VERSION)-config"
        let kde_path_result = (^$kde_config_cmd --path mime | complete)
        if ($kde_path_result.exit_code) == 0 {
            let kde_global_dirs = (($kde_path_result.stdout) | str trim)
            mut first = true
            for x in ($kde_global_dirs | split row ":") {
                if ($x | is-empty) { continue }
                if $first {
                    $kde_user_dir = $x
                    $first = false
                } else if (is-writable $x) {
                    $kde_global_dir = $x
                }
            }
        }
    }

    DEBUG 3 $"kde_user_dir: ($kde_user_dir)"
    DEBUG 3 $"kde_global_dir: ($kde_global_dir)"

    # TODO: Gnome legacy support
    # See http://forums.fedoraforum.org/showthread.php?t=26875
    let gnome_user_dir = ($env.HOME | path join ".gnome" "apps")
    mut gnome_global_dir = "/usr/share/gnome/apps"
    if not (is-writable $gnome_global_dir) {
        $gnome_global_dir = ""
    }

    DEBUG 3 $"gnome_user_dir: ($gnome_user_dir)"
    DEBUG 3 $"gnome_global_dir: ($gnome_global_dir)"

    # Select directories based on mode
    let dirs = if $mode == "user" {
        [$xdg_user_dir, $kde_user_dir, $gnome_user_dir]
    } else {
        if (($xdg_global_dir | is-empty) and ($kde_global_dir | is-empty) and ($gnome_global_dir | is-empty)) {
            exit_failure_operation_impossible "No writable system mimetype directory found."
        }
        [$xdg_global_dir, $kde_global_dir, $gnome_global_dir]
    }
    let dir = ($dirs | get 0)
    let kde_dir = ($dirs | get 1)

    let basefile = ($filename | path basename)

    # Extract mimetypes from XML if KDE directory is available
    let mimetypes = if not ($kde_dir | is-empty) {
        DEBUG 2 "KDE3 mimelnk directory found, extracting mimetypes from XML file"
        extract_mimetypes_from_xml $filename
    } else {
        []
    }

    DEBUG 1 $"install mimetype in ($dir)"

    # Copy XML file to XDG directory
    mkdir $dir
    cp $filename ($dir | path join $basefile)

    # Create KDE desktop files for each mimetype
    if not ($mimetypes | is-empty) {
        for x in $mimetypes {
            DEBUG 1 $"Installing ($kde_dir)/($x).desktop (KDE 3.x support)"
            let success = (create_kde_desktop_from_xml $filename $x $kde_dir)
            if not $success {
                let desktop_file = ($kde_dir | path join $"($x).desktop")
                if ($desktop_file | path type) == "file" {
                    rm $desktop_file
                }
                exit 1
            }
        }
    }

    update_mime_database $mode
}

# Uninstall mimetypes from XML file
def --env uninstall_mimetypes [filename: string, mode: string] {
    let xdg_dir_name = "mime/packages/"

    # Determine user directory
    let xdg_user_dir = if not ($env.XDG_DATA_HOME? == null) { $env.XDG_DATA_HOME } else { $env.HOME | path join ".local" "share" }
    let xdg_user_dir = ($xdg_user_dir | path join $xdg_dir_name)

    # Determine system directories
    let xdg_system_dirs = if not ($env.XDG_DATA_DIRS? == null) { $env.XDG_DATA_DIRS } else { "/usr/local/share/:/usr/share/" }

    # Find writable system directory
    mut xdg_global_dir = ""
    for x in ($xdg_system_dirs | split row ":") {
        if ($x | is-empty) { continue }
        let test_dir = ($x | path join $xdg_dir_name)
        if (($test_dir | path type) == "dir" and (is-writable $test_dir)) {
            $xdg_global_dir = $test_dir
            break
        }
    }

    # Find KDE3 mimelnk directory
    mut kde_dir = ""
    if not ($env.KDE_SESSION_VERSION? == null) {
        let kde_config_cmd = $"kde($env.KDE_SESSION_VERSION)-config"
        let kde_path_result = (^$kde_config_cmd --path mime | complete)
        if ($kde_path_result.exit_code) == 0 {
            let kde_global_dirs = (($kde_path_result.stdout) | str trim)
            for x in ($kde_global_dirs | split row ":") {
                if ($x | is-empty) { continue }
                $kde_dir = $x
                break
            }
        }
    }

    # Select directory based on mode
    let dir = if $mode == "user" {
        $xdg_user_dir
    } else {
        $xdg_global_dir
    }

    let basefile = ($filename | path basename)

    DEBUG 1 $"uninstall mimetype in ($dir)"

    # Remove XML file from XDG directory
    let target_file = ($dir | path join $basefile)
    if ($target_file | path type) == "file" {
        rm $target_file
    }

    # Extract mimetypes and remove KDE desktop files
    if not ($kde_dir | is-empty) {
        let mimetypes = (extract_mimetypes_from_xml $filename)
        for x in $mimetypes {
            let desktop_file = ($kde_dir | path join $"($x).desktop")
            if ($desktop_file | path type) == "file" {
                let check_result = (^grep "^# Installed by xdg-mime" $desktop_file | complete)
                if ($check_result.exit_code) == 0 {
                    DEBUG 1 $"Removing ($desktop_file) (KDE 3.x support)"
                    rm $desktop_file
                }
            }
        }
    }

    update_mime_database $mode
}

# Search for desktop files that support a MIME type
def --env search_desktop_file [mimetype: string, dir: string] {
    let results = (ls $dir | where {|f| ($f.name | path type) == "file" and ($f.name | path parse | get extension) == "desktop" and ((^grep -l $"($mimetype);" $f.name | complete).exit_code == 0) })
    for f in $results {
        print $f.name
    }

    for subdir in (ls $dir | where {|f| ($f.name | path type) == "dir" }) {
        search_desktop_file $mimetype $subdir.name
    }
}

## defapp_* functions that print the matching desktop file name for a given mimetype.

# Query default application generically
def --env defapp_fallback [mimetype: string] {
    let xdg_user_dir = if not ($env.XDG_DATA_HOME? == null) { $env.XDG_DATA_HOME } else { $env.HOME | path join ".local" "share" }
    let xdg_system_dirs = if not ($env.XDG_DATA_DIRS? == null) { $env.XDG_DATA_DIRS } else { "/usr/local/share/:/usr/share/" }

    mut preference = -1
    mut desktop_file = ""

    for dir in ([$xdg_user_dir] | append ($xdg_system_dirs | split row ":") | flatten) {
        let apps_dir = ($dir | path join "applications")
        if ($apps_dir | path type) == "dir" {
            for x in (search_desktop_file $mimetype $apps_dir) {
                let pref_text = (^awk -F"=" "/InitialPreference=/ {print($2)}" $x | complete | get stdout | str trim)
                let pref = ($pref_text | try { into int } catch { 0 })
                DEBUG 2 $" Checking ($x)"
                if $pref > $preference {
                    DEBUG 2 $"   Select ($x) [ ($preference) => ($pref) ]"
                    $preference = $pref
                    $desktop_file = $x
                }
            }
        }
    }

    if not ($desktop_file | is-empty) {
        print ($desktop_file | path parse | get stem)
        exit_success
    }
}

# Check for the given mimetype in the appropriate mimeapps.list files
# in the given directory.
# Prints the name of the desktop file that should handle the given mimetype.
# Exits on success, returns otherwise.
# (mimetype, in_directory)
def --env check_mimeapps_list [mimetype: string, dir: string] {
    for desktop in (($env.XDG_CURRENT_DESKTOP? | default "" | split row ":") | append "") {
        let prefix = if (not ($desktop | is-empty)) { ($desktop | str downcase | str replace --all " " "-") } else { "" }
        let mimeapps_list = ($dir | path join $"($prefix)mimeapps.list")
        if ($mimeapps_list | path type) == "file" {
            DEBUG 2 $"Checking ($mimeapps_list)"
            let result = (^awk $"-v mimetype=($mimetype)" '
BEGIN { prefix=mimetype "="; indefault=0; found=0 }
{
    if (index($0, "[Default Applications]") == 1) {
        indefault=1
    } else if (index($0, "[") == 1) {
        indefault=0
    } else if (!found && indefault && index($0, prefix) == 1) {
        print substr($0, length(prefix) +1, length())
        found=1
    }
}
' $mimeapps_list | complete)
            if not (($result.stdout) | is-empty) {
                let app_list = (($result.stdout) | split row ";")
                for app in $app_list {
                    if (not ($app | is-empty)) and (desktop_file_to_binary $app | is-not-empty) {
                        print $app
                        exit_success
                    }
                }
            }
        }
    }
}

# Query default application generically
def --env defapp_generic [mimetype: string] {
    let xdg_config_home = (get_xdg_config_home)
    let xdg_config_dirs = ($env.XDG_CONFIG_DIRS? | default "/etc/xdg")
    let xdg_user_dir = if not ($env.XDG_DATA_HOME? == null) { $env.XDG_DATA_HOME } else { $env.HOME | path join ".local" "share" }
    let xdg_system_dirs = if not ($env.XDG_DATA_DIRS? == null) { $env.XDG_DATA_DIRS } else { "/usr/local/share/:/usr/share/" }

    for dir in ([$xdg_config_home] | append ($xdg_config_dirs | split row ":") | flatten) {
        check_mimeapps_list $mimetype $dir
    }

    for dir in ([$xdg_user_dir] | append ($xdg_system_dirs | split row ":") | flatten) {
        check_mimeapps_list $mimetype ($dir | path join "applications")
    }

    for base_dir in ([$xdg_user_dir] | append ($xdg_system_dirs | split row ":") | flatten) {
        for prefix in (($env.XDG_MENU_PREFIX? | default "" | split row ":") | append [""] | flatten) {
            DEBUG 2 $"Checking ($base_dir)/applications/($prefix)defaults.list and ($base_dir)/applications/($prefix)mimeinfo.cache"
            let defaults_list = ($base_dir | path join "applications" $prefix "defaults.list")
            let mimeinfo_cache = ($base_dir | path join "applications" $prefix "mimeinfo.cache")
            if (($defaults_list | path type) == "file" or ($mimeinfo_cache | path type) == "file") {
                let result = (^grep $"($mimetype)=" $"($defaults_list)" $"($mimeinfo_cache)" | complete | get stdout)
                if not ($result | is-empty) {
                    let trader_result = ($result | split row "=" | get 1? | default "" | split row ";" | get 0? | default "")
                    if not ($trader_result | is-empty) {
                        print $trader_result
                        exit_success
                    }
                }
            }
        }
    }

    defapp_fallback $mimetype
}

# Query default application using KDE
def --env defapp_kde [mimetype: string] {
    let version = ($env.KDE_SESSION_VERSION? | default "" | try { into int } catch { 0 })
    let trader = if $version == 4 {
        (which ktraderclient | get 0?.path | default "")
    } else if $version == 5 {
        (which $"ktraderclient($version)" | get 0?.path | default "")
    } else {
        (which ktradertest | get 0?.path | default "")
    }

    if not ($trader | is-empty) {
        DEBUG 1 $"Running KDE trader query '($mimetype)'"
        let result = (^$trader --mimetype $mimetype --servicetype Application | complete | get stdout)
        if not ($result | is-empty) {
            let desktop_line = ($result | ^grep -E '^DesktopEntryPath : |\.desktop$' | complete | get stdout | lines | get 0? | default "")
            let desktop = ($desktop_line | str replace --regex "^DesktopEntryPath : '(.*\\.desktop)'$" "$1" | str trim)
            if not ($desktop | is-empty) {
                print ($desktop | path parse | get stem)
                exit_success
            }
        }
    }
    defapp_generic $mimetype
}

# Query default application using LXQt
def --env defapp_lxqt [mimetype: string] {
    if (^qtxdg-mat defapp --help | complete).exit_code == 0 {
        let result = (^qtxdg-mat defapp $mimetype | complete)
        if ($result.exit_code) == 0 {
            print (($result.stdout) | str trim)
            exit_success
        }
    }
    exit_failure_operation_impossible $"no method available for querying the default application for MIME type of '($mimetype)'"
}

# xdg-mime - command line tool for querying information about file type handling and adding descriptions for new file types
# Synopsis: xdg-mime query { filetype FILE | default mimetype }
# Synopsis: xdg-mime default application mimetype(s)
# Synopsis: xdg-mime install [--mode mode] [--novendor] mimetypes-file
# Synopsis: xdg-mime uninstall [--mode mode] mimetypes-file
# Synopsis: xdg-mime { --help | --manual | --version }
def --wrapped main [...args] {
    let args = ($args | each { into string })
    handle_standard_options "xdg-mime" $args [
        "xdg-mime - command line tool for querying information about file type handling and adding descriptions for new file types"
        ""
        "Synopsis"
        ""
        "xdg-mime query { filetype FILE | default mimetype }"
        "xdg-mime default application mimetype(s)"
        "xdg-mime install [--mode mode] [--novendor] mimetypes-file"
        "xdg-mime uninstall [--mode mode] mimetypes-file"
        ""
        "xdg-mime { --help | --manual | --version }"
    ]

    if ($args | is-empty) {
        exit_failure_syntax
    }

    mut mode = ""
    mut action = ""
    mut filename = ""
    mut mimetype = ""

    let cmd = ($args | get 0)
    let args = ($args | skip 1)

    match $cmd {
        "install" => {
            $action = "install"
            # Parse remaining arguments for --mode flag
            mut i = 0
            while $i < ($args | length) {
                let arg = ($args | get $i)
                if $arg == "--mode" {
                    $i = $i + 1
                    if $i >= ($args | length) {
                        exit_failure_syntax "mode argument missing for --mode"
                    }
                    let value = ($args | get $i)
                    match $value {
                        "user" => { $mode = "user" }
                        "system" => { $mode = "system" }
                        _ => { exit_failure_syntax $"unknown mode '($value)'" }
                    }
                } else if $arg == "--novendor" {
                    # Ignored for compatibility
                } else if not ($filename | is-empty) {
                    exit_failure_syntax $"unexpected argument '$arg'"
                } else {
                    $filename = $arg
                }
                $i = $i + 1
            }
        }
        "uninstall" => {
            $action = "uninstall"
            # Parse remaining arguments for --mode flag
            mut i = 0
            while $i < ($args | length) {
                let arg = ($args | get $i)
                if $arg == "--mode" {
                    $i = $i + 1
                    if $i >= ($args | length) {
                        exit_failure_syntax "mode argument missing for --mode"
                    }
                    let value = ($args | get $i)
                    match $value {
                        "user" => { $mode = "user" }
                        "system" => { $mode = "system" }
                        _ => { exit_failure_syntax $"unknown mode '($value)'" }
                    }
                } else if not ($filename | is-empty) {
                    exit_failure_syntax $"unexpected argument '$arg'"
                } else {
                    $filename = $arg
                }
                $i = $i + 1
            }
        }
        "query" => {
            $action = "query"
            if ($args | is-empty) {
                exit_failure_syntax "query type argument missing"
            }
            let query_type = ($args | get 0)
            let args = ($args | skip 1)

            match $query_type {
                "filetype" => {
                    $action = "info"
                    $filename = ($args | get 0? | default "")
                    if ($filename | is-empty) {
                        exit_failure_syntax "FILE argument missing"
                    }
                    if ($filename | str starts-with "-") {
                        exit_failure_syntax $"unexpected option '($filename)'"
                    }
                    check_input_file $filename
                    $filename = (xdg_realpath $filename | default $filename)
                }
                "default" => {
                    $action = "defapp"
                    $mimetype = ($args | get 0? | default "")
                    if ($mimetype | is-empty) {
                        exit_failure_syntax "mimetype argument missing"
                    }
                    if ($mimetype | str starts-with "-") {
                        exit_failure_syntax $"unexpected option '($mimetype)'"
                    }
                    if not ($mimetype | str contains "/") {
                        exit_failure_syntax $"mimetype '($mimetype)' is not in the form 'minor/major'"
                    }
                }
            }
        }
        "default" => {
            $action = "makedefault"
            $filename = ($args | get 0? | default "")
            if ($filename | is-empty) {
                exit_failure_syntax "application argument missing"
            }
            if ($filename | str starts-with "-") {
                exit_failure_syntax $"unexpected option '($filename)'"
            }
            if not ($filename | str ends-with ".desktop") {
                exit_failure_syntax $"malformed argument '($filename)', expected *.desktop"
            }
        }
    }

    detectDE

    if $action == "makedefault" {
        # Skip $args.0, which is the .desktop filename already captured above.
        let mimetypes = ($args | skip 1)
        if ($mimetypes | is-empty) {
            exit_failure_syntax "mimetype argument missing"
        }
        let binary = (desktop_file_to_binary $filename)
        if ($binary | is-empty) {
            print "The given .desktop file doesn't exist or doesn't have an Exec key that points to a program."
            print "To get more information run with: XDG_UTILS_DEBUG_LEVEL=4 xdg-mime makedefault …"
            exit_failure_file_missing
        }

        let de = ($env.DE? | default "")
        for mimetype_arg in $mimetypes {
            if ($mimetype_arg | str starts-with "-") {
                exit_failure_syntax $"unexpected option '($mimetype_arg)'"
            }
            if $de == "lxqt" {
                make_default_lxqt $filename $mimetype_arg
            }
            if $de == "kde" {
                make_default_kde $filename $mimetype_arg
            }
            make_default_generic $filename $mimetype_arg
        }

        if $de == "kde" {
            update_kde_cache
        }
        exit_success
    }

    if $action == "info" {
        detectDE
        if ($env.DE? | default "" | is-empty) {
            if (which file | is-not-empty) {
                $env.DE = "generic"
            }
        }

        match $env.DE {
            "kde" => { info_kde $filename }
            "gnome" | "cinnamon" | "lxde" | "mate" | "xfce" | "budgie" => { info_gnome $filename }
            "lxqt" => { info_lxqt $filename }
            _ => {}
        }
        info_generic $filename
        exit_failure_operation_impossible $"no method available for querying MIME type of '($filename)'"
    }

    if $action == "defapp" {
        detectDE
        if ($env.DE? | default "") == "kde" and (($env.KDE_SESSION_VERSION? | default "0" | try { into int } catch { 0 }) < 6) {
            defapp_kde $mimetype
        }

        match $env.DE {
            "lxqt" => { defapp_lxqt $mimetype }
            _ => {}
        }
        defapp_generic $mimetype
        exit_failure_operation_impossible $"no method available for querying default application for '($mimetype)'"
    }

    if $action == "install" {
        # Check if filename is provided
        if ($filename | is-empty) {
            exit_failure_syntax "mimetypes-file argument missing"
        }

        # Check vendor prefix
        check_vendor_prefix $filename

        # Determine mode
        if not ($env.XDG_UTILS_INSTALL_MODE? == null) {
            if $env.XDG_UTILS_INSTALL_MODE == "system" {
                $mode = "system"
            } else if $env.XDG_UTILS_INSTALL_MODE == "user" {
                $mode = "user"
            }
        }

        if ($mode | is-empty) {
            let uid_result = (^id -u | complete | get stdout | str trim | into int)
            if $uid_result == 0 {
                $mode = "system"
            } else {
                $mode = "user"
            }
        }

        check_input_file $filename
        install_mimetypes $filename $mode
        exit_success
    }

    if $action == "uninstall" {
        # Check if filename is provided
        if ($filename | is-empty) {
            exit_failure_syntax "mimetypes-file argument missing"
        }

        # Determine mode
        if not ($env.XDG_UTILS_INSTALL_MODE? == null) {
            if $env.XDG_UTILS_INSTALL_MODE == "system" {
                $mode = "system"
            } else if $env.XDG_UTILS_INSTALL_MODE == "user" {
                $mode = "user"
            }
        }

        if ($mode | is-empty) {
            let uid_result = (^id -u | complete | get stdout | str trim | into int)
            if $uid_result == 0 {
                $mode = "system"
            } else {
                $mode = "user"
            }
        }

        uninstall_mimetypes $filename $mode
        exit_success
    }
}
