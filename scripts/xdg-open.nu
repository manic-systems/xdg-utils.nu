#!/usr/bin/env nu
# xdg-open - Open a URL in the registered default application

$env.XDG_UTILS_ENABLE_DOUBLE_HYPEN = "y"

# Load common functions
use xdg-utils-common.nu *

# Check if string is a URL scheme
def has_url_scheme [text: string] {
    let pattern = "^[[:alpha:]][[:alpha:][:digit:]+.-]*:"
    ($text | ^grep -Eq $pattern | complete).exit_code == 0
}

# Check if argument is a file:// URL or path
def is_file_url_or_path [url_or_path: string] {
    ($url_or_path | str starts-with "file://") or not (has_url_scheme $url_or_path)
}

# Get hostname
def --env get_hostname [] {
    if ($env.HOSTNAME? | default "" | is-empty) {
        if (which hostname | is-not-empty) {
            $env.HOSTNAME = (^hostname | complete | get stdout | str trim)
        } else {
            $env.HOSTNAME = (^uname -n | complete | get stdout | str trim)
        }
    }
    $env.HOSTNAME? | default ""
}

# Convert file:// URL to path
def --env file_url_to_path [file: string] {
    get_hostname
    if ($file | str starts-with "file://") {
        mut f = $file
        $f = ($f | str replace --regex "^file://localhost" "")
        $f = ($f | str replace --regex $"^file://($env.HOSTNAME? | default '')" "")
        $f = ($f | str replace --regex "^file://" "")

        if not ($f | str starts-with "/") {
            return $f
        }
        $f = ($f | split row "#" | get 0)
        $f = ($f | split row "?" | get 0)

        let printf_cmd = if (which printf | is-not-empty) { "printf" } else { "/usr/bin/printf" }
        $f = (^$printf_cmd ($f | ^sed -e "s@%\\([a-f0-9A-F]\\{2\\}\\)@\\\\x\\1@g" | complete | get stdout) | complete | get stdout | str trim)
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
    if (^dde-open -version | complete | get exit_code) == 0 {
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
    let result = if (^gio help open | complete | get exit_code) == 0 {
        (^gio open $url | complete)
    } else if (^gvfs-open --help | complete | get exit_code) == 0 {
        (^gvfs-open $url | complete)
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
    let result = if (^gio help open | complete | get exit_code) == 0 {
        (^gio open $url | complete)
    } else if (^gvfs-open --help | complete | get exit_code) == 0 {
        (^gvfs-open $url | complete)
    } else if (^gnome-open --help | complete | get exit_code) == 0 {
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
    let result = if (^gio help open | complete | get exit_code) == 0 {
        (^gio open $url | complete)
    } else if (^gvfs-open --help | complete | get exit_code) == 0 {
        (^gvfs-open $url | complete)
    } else if (^mate-open --help | complete | get exit_code) == 0 {
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
    let result = if (^xfce-open --help | complete | get exit_code) == 0 {
        (^xfce-open $url | complete)
    } else if (^exo-open --help | complete | get exit_code) == 0 {
        (^exo-open $url | complete)
    } else if (^gio help open | complete | get exit_code) == 0 {
        (^gio open $url | complete)
    } else if (^gvfs-open --help | complete | get exit_code) == 0 {
        (^gvfs-open $url | complete)
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
    let result = if (^enlightenment_open --help | complete | get exit_code) == 0 {
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

# Open using D-Bus portal
def --env open_gdbus [url: string] {
    # Normalize local paths into file:// URIs.
    let target = if (is_file_url_or_path $url) {
        let file = (file_url_to_path $url)
        check_input_file $file
        $"file://(($file | path expand))"
    } else {
        $url
    }

    let result = (^gdbus call --session
        --dest org.freedesktop.portal.Desktop
        --object-path /org/freedesktop/portal/desktop
        --method org.freedesktop.portal.OpenURI.OpenURI
        --timeout 5
        "" $target "{}" | complete)

    if ($result.exit_code) == 0 {
        exit_success
    } else {
        exit_failure_operation_failed
    }
}


# Recursively search .desktop file

# The awk script for parsing .desktop files (embedded from original xdg-open.in)
const AWK_SCRIPT_OPEN_WITH_DESKTOP_FILE = '
BEGIN {

	debug_level = ENVIRON["XDG_UTILS_DEBUG_LEVEL"]

	if (uri_arg) {
		split(uri_arg, split_uri_arg, " ")
	}

	has_uri = 0;
	filec = 0;
	for (i=1; split_uri_arg[i]; i++) {
		has_uri = 1;
		uri = split_uri_arg[i]
		uris[i-1] = uri;
		debug(2, "URI: " uri)
		if (file_arg != "") {
			file = decode_local_file_uri(uri)
			if (file) {
				debug(2, "File: " file)
				files[filec] = file;
				filec = filec + 1;
			}
		}
	}

	if (file_arg != "") {
		debug(2, "File: " file_arg)
		files[filec] = file_arg;
		filec = filec + 1;
		if (!has_uri) {
			debug(2, "URI (falling back to file path): " file_arg)
			uris[0] = file_arg
		}
	}

	in_main_section = 0;

	exec_value = 0;
	term_value = 0;
	icon_value = 0;
	name_value = 0;
}

/^\[/ {
	in_main_section = 0;
}

$0 == "[Desktop Entry]" {
	in_main_section = 1
}

function unescape_value(escaped) {
	value = ""
	for (i=1; i<=length(escaped); i++) {
		char = substr(escaped, i, 1)
		if (char == "\\") {
			i = i+1
			next_char = substr(escaped,i,1);
			if (next_char == "s") {
				value = value " ";
			} else if (next_char == "n") {
				value = value "\n";
			} else if (next_char == "t") {
				value = value "\t";
			} else if (next_char == "r") {
				value = value "\r";
			} else if (next_char == "\\") {
				value = value "\\";
			}
		} else {
			value = value char
		}
	}
	return value;
}

function split_exec_value(value, out_args) {
	argc = 0;
	in_quote = 0;
	current_arg = "";
	next_is_literal = 0;
	for (i=1; i<=length(value); i++) {
		char = substr(value,i,1)
		if (next_is_literal) {
			next_is_literal = 0;
			current_arg = current_arg char
			continue
		}
		if (in_quote) {
			if (char == "\"") {
				in_quote = 0;
				out_args[argc] = current_arg;
				argc = argc + 1;
				current_arg = "";
			} else if (char == "\\") {
				next_is_literal = 1;
			} else {
				current_arg = current_arg char
			}
		} else {
			if (current_arg == "" && char == "\"") {
				in_quote = 1;
			} else if (char != " ") {
				current_arg = current_arg char
			} else if (current_arg != "") {
				out_args[argc] = current_arg;
				argc = argc + 1;
				current_arg = "";
			}
		}
	}
	if (current_arg != "") {
		out_args[argc] = current_arg;
	}
}

function hex_value(char) {
	value = char - "0";
	if (value >= 0 && value < 10) {
		return value;
	}
	value = char - "a";
	if (value >= 10 && value < 16) {
		return value;
	}
	value = char - "A";
	if (value >= 10 && value < 16) {
		return value;
	}
	return 0;
}

function uri_decode(text) {
	output = ""
	for (i=1; i<=length(text); i++) {
		char = substr(text, i, 1);
		if (char != "%") {
			output = output char;
			continue
		}
		char_a = substr(text, i+1, 1);
		char_b = substr(text, i+2, 1);
		i = i+2;
		numeric = hex_value(char_a)*16+hex_value(char_b);
		if (numeric != 0 && numeric != 47) {
			output = output sprintf("%c", numeric)
		}
	}
	return output;
}

function decode_local_file_uri(uri) {
	if (!match(uri, /^file:\\/\\//)) {
		return 0;
	}
	host = ""
	path = 0
	slash_count = 0
	host_start = 0
	host_end = 0
	path_start = 0
	for (i=1; i<=length(uri); i++) {
		char = substr(text, i, 1);
		if (char == "/") {
			slash_count++;
			if (slash_count == 2) {
				host_start = i;
			}
			if (slash_count == 3) {
				path_start = i;
			}
			continue
		} else if (host_start && char == ":") {
			host_end = i;
		} else if (char == "?" || char == "#") {
			if (path_start) {
				path = substr(uri, path_start, i - path_start)
			}
			# ignore that we would not fully parse the hostname in this case,
			# if the hostname is not finished here it will fail anyway.
			break
		}
		if (host_start && host_end) {
			host = substr(uri, host_start, host_end - host_start);
		}
	}
	# Hostname must either be empty, "localhost" or match local hostname
	if (host != "" && host != "localhost" && host != hostname) {
		return 0;
	}
	if (path) {
		return uri_decode(path)
	}
	return 0;
}

function debug(level, text) {
	if (!debug_level) {
		return;
	}
	if (level <= debug_level) {
		print "DEBUG: " text >> "/dev/stderr";
	}
}

function error(text) {
	printf("err\\0");
	print "xdg-open ERROR: " text >> "/dev/stderr";
	exit 4
}

in_main_section && match($0, /^[^#=\[]+\[?[^=\]]*\]?=/) {
	index_of_eq = index($0, "=");
	index_of_bracket_open = index($0, "[");
	if (index_of_bracket_open && index_of_bracket_open < index_of_eq) {
		key = substr($0, 1, index_of_bracket_open-1)
		local = substr($0, index_of_bracket_open+1, index_of_eq-index_of_bracket_open-2);
	} else {
		key = substr($0, 1, index_of_eq-1);
		local = "";
	}
	value = substr($0, index_of_eq+1);
	debug(4, "Key: " key " Local: " local " Value: " value);
	if (key == "Exec") {
		exec_value = unescape_value(value);
	} else if (key == "Terminal") {
		term_value = value;
	} else if (key == "Icon") {
		icon_value = unescape_value(value);
	} else if (key == "Name") {
		# TODO: handle actual localization
		if (local == "") {
			name_value = unescape_value(value)
		}
	}
}

END {
	if (!exec_value) {
		print "xdg-open: No Exec= line found in main section of desktop file!" >> "/dev/stderr";
		exit 1;
	}
	debug(2, "Unescaped: " exec_value)
	split_exec_value(exec_value, args)
	# Field code expansion
	expanded_args[0] = "";
	eargc = 0;
	if (term_value == "true") {
		expanded_args[0] = "xdg-terminal";
		eargc = 1;
	}
	found_file_field_codes = 0;
	for (i=0; args[i]; i++) {
		arg = args[i];
		debug(2, "Running field code expansion on arg: " arg);
		if (arg == "%F") {
			for (j=0; j<length(files); j++) {
				expanded_args[eargc] = files[j];
				eargc = eargc + 1;
			}
			found_file_field_codes++;
			continue
		} else if (arg == "%U") {
			for (j=0; j<length(uris); j++) {
				expanded_args[eargc] = uris[j];
				eargc = eargc + 1;
			}
			found_file_field_codes++;
			continue
		} else if (arg == "%i") {
			if (icon_value) {
				expanded_args[eargc] = "--icon"
				expanded_args[eargc] = icon_value
				eargc = eargc + 1;
			}
			continue
		}
		debug(2, "Trying to find in-text field code ...");
		expanded_arg = ""
		for (j=1; j<=length(arg); j++) {
			char = substr(arg,j,1);
			if (char != "%") {
				expanded_arg = expanded_arg char
				continue
			}
			j = j+1;
			char = substr(arg,j,1);
			debug(2, "Found field code expansion: %" char);
			if (char == "%") {
				expanded_arg = expanded_arg "%"
			} else if (char == "f") {
				# Take just the first arg for the prototype
				expanded_arg = expanded_arg files[0];
				found_file_field_codes++;
			} else if (char == "u") {
				# Take just the first arg for the prototype
				expanded_arg = expanded_arg uris[0];
				found_file_field_codes++;
			} else if (char == "c") {
				if (name_value) {
					expanded_arg = expanded_arg name_value
				}
			} else if (char == "k") {
				# Location of desktop file either as URI or local filename
				# Ignore for now
				# TODO
			} else if (char == "d" || char == "D" || char == "n" || char == "N") {
				# Deprecated, silently remove
			} else if (char == "i" || char == "U" || char == "F") {
				error("xdg-open: Field code %" char "must be stand alone as it expands into multiple arguments!")
			} else {
				error("xdg-open: Unknown field code: %" char " in Exec key!")
			}
		}
		if (found_file_field_codes > 1) {
			error("xdg-open: More than one file field codes (%f, %F, %u, %U) in Exec key, this .desktop file is invalid!")
		}
		expanded_args[eargc] = expanded_arg;
		eargc = eargc + 1;
	}

	if (found_file_field_codes == 0) {
		debug(1, "Did not find a file field code (%f, %F, %u, %U), appending filepath/url as last argument");
		if (files[0]) {
			expanded_args[eargc] = files[0];
		} else {
			expanded_args[eargc] = uris[0];
		}
		eargc = eargc + 1;
	}

	printf("cmd\\0");
	for (i=0; expanded_args[i]; i++) {
		debug(1, "Arg: " expanded_args[i]);
		printf("%s\\0", expanded_args[i]);
	}
	exit
}
'

# Open a file using a desktop file entry
# (desktop_file, file, uri (optional))
def --env open_with_desktop_file [desktop_file: string, file: string, uri: string = ""] {
    get_hostname
    let hostname = (get_hostname)

    # Run awk script and capture output
    let awk_cmd = $"
awk -v\"hostname=($hostname)\" -v\"file_arg=($file)\" -v\"uri_arg=($uri)\" '($AWK_SCRIPT_OPEN_WITH_DESKTOP_FILE)' < \"($desktop_file)\""

    let result = (^sh -c $awk_cmd | complete)

    if ($result.exit_code) != 0 {
        # Check if awk produced error output
        if not (($result.stdout) | is-empty) and (($result.stdout) | str starts-with "err") {
            exit_failure_operation_failed
        }
    }

    # Parse the null-terminated output
    # First 4 bytes are "cmd\0" followed by null-terminated arguments
    if (($result.stdout) | is-empty) {
        exit_failure_operation_failed
    }

    let parts = (($result.stdout) | split row "\u{0}")
    if ($parts | length) == 0 {
        exit_failure_operation_failed
    }

    let first = ($parts | get 0)
    if $first != "cmd" {
        exit_failure_operation_failed
    }

    let cmd_parts = ($parts | skip 1 | where { not ($it | is-empty) })
    if ($cmd_parts | length) == 0 {
        exit_failure_operation_failed
    }

    let cmd = ($cmd_parts | get 0)
    let args = ($cmd_parts | skip 1)

    # Execute the command
    let sh_script = $"exec ($cmd) " | append $args | str join ' '
    let exec_result = (^sh -c $sh_script | complete)
    if ($exec_result.exit_code) == 123 {
        exit_failure_operation_failed
    }
    if ($exec_result.exit_code) != 0 {
        exit_failure_operation_failed
    }

    exit_success
}

# Search desktop files for default application
# Handles both vendor-app.desktop and vendor/app.desktop paths
def --env search_desktop_file [default: string, dir: string, target: string, target_uri: string = ""] {
    let candidate = ($dir | path join $default)
    if not (($candidate | path type) == "file" and ($candidate | path parse | get extension) == "desktop") {
        # try vendor/app.desktop format (replace first - with /)
        let alt_path = ($dir | path join ($default | ^sed -r 's/-/\//') | complete | get stdout | str trim)
        if (($alt_path | path type) == "file" and ($alt_path | path parse | get extension) == "desktop") {
            open_with_desktop_file $alt_path $target $target_uri
            exit_success
        }
    } else {
        open_with_desktop_file $candidate $target $target_uri
        exit_success
    }

    for d in (ls $dir) {
        if ($d.name | path type) == "dir" {
            search_desktop_file $default $d.name $target $target_uri
        }
    }
}

# Open using xdg-mime
# (file (or empty), mimetype, optional url)
def --env open_generic_xdg_mime [file: string, filetype: string, url: string = ""] {
    let default_app = (^xdg-mime query default $filetype | complete | get stdout | str trim)
    if ($default_app | is-empty) { return }

    let xdg_user_dir = if not ($env.XDG_DATA_HOME? == null) { $env.XDG_DATA_HOME } else { $env.HOME | path join ".local" "share" }
    let xdg_system_dirs = if not ($env.XDG_DATA_DIRS? == null) { $env.XDG_DATA_DIRS } else { "/usr/local/share/:/usr/share/" }
    let search_dirs = ($"($xdg_user_dir):($xdg_system_dirs)" | split row ":")

    for dir in $search_dirs {
        let app_dir = ($dir | path join "applications")
        if ($app_dir | path type) == "dir" {
            search_desktop_file $default_app $app_dir $file $url
        }
    }
}

# Open an url using the x-scheme-handler/<scheme> dummy mimetype
def --env open_generic_xdg_x_scheme_handler [url: string] {
    let scheme = ($url | ^sed -n "s/^\\([[:alpha:]][[:alnum:]+\\.-]*\\):.*/\\1/p" | complete | get stdout | str trim)
    if ($scheme | is-empty) { return }

    let filetype = $"x-scheme-handler/($scheme)"
    open_generic_xdg_mime $url $filetype
}

# Check single argument
def has_single_argument [arg_count: int] {
    $arg_count == 1
}

# Open using BROWSER env var
def --env open_envvar [url: string] {
    if ($env.BROWSER? | default "" | is-empty) { return }

    let browsers = ($env.BROWSER | split row ":")
    for browser in $browsers {
        if ($browser | is-empty) { continue }

        if ($browser | str contains "%s") {
            # Substitute %s with the URL, then run with sh
            let formatted = (^printf $browser $url | complete | get stdout)
            if ($formatted | is-empty) { continue }
            let result = (^sh -c $formatted | complete)
            if ($result.exit_code) == 0 {
                exit_success
            }
        } else {
            let result = (^$browser $url | complete)
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

        if (has_display) and ((^mimeopen -v | complete | get exit_code) == 0) {
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
    if (^pcmanfm --help | complete | get exit_code) == 0 and (is_file_url_or_path $url) {
        mut file = (file_url_to_path $url)
        if not ($file | str starts-with "/") {
            $file = ([$"(pwd)" $file] | path join)
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
    if (^qtxdg-mat open --help | complete | get exit_code) == 0 {
        let result = (^qtxdg-mat open $url | complete)
        if ($result.exit_code) == 0 {
            exit_success
        }
        exit_failure_operation_failed
    }
    exit_failure_operation_impossible "no method available for opening '$url'"
}

# Dispatch to correct opener based on DE
def --env open_one_argument [url: string] {
    match $env.DE {
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
        "flatpak" => { open_gdbus $url }
        "toolbx" => { open_gdbus $url }
        "wsl" => { open_wsl $url }
        "generic" => { open_generic $url }
    }
}

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
