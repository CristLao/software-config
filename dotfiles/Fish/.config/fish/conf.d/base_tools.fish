# Bat
batman --export-env | source

# Zoxide
zoxide init fish | source

# Yazi
abbr yz yazi
function yy
	set tmp (mktemp -t "yazi-cwd.XXXXXX")
	command yazi $argv --cwd-file="$tmp"
	if read -z cwd < "$tmp"; and [ "$cwd" != "$PWD" ]; and test -d "$cwd"
		builtin cd -- "$cwd"
	end
	rm -f -- "$tmp"
end

# Mise
mise activate fish | source
