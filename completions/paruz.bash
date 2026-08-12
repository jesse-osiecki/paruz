# SPDX-License-Identifier: GPL-3.0-or-later
# bash completion for paruz

_paruz() {
	local cur prev
	cur="${COMP_WORDS[COMP_CWORD]}"
	prev="${COMP_WORDS[COMP_CWORD - 1]}"

	local ops="-S -Syu -Su -Sua -Sy -Q -Qua -R -Ss -Si -G -F -Sc doctor"
	local flags="--fail-on --allow-maintainer-change --replay-hook --no-flatpak --no-ioc --sandbox= --dry-run --help --version"

	case "$prev" in
		--fail-on)
			COMPREPLY=( $(compgen -W "critical high medium low info" -- "$cur") )
			return 0
			;;
		--sandbox)
			COMPREPLY=( $(compgen -W "chroot gvisor" -- "$cur") )
			return 0
			;;
		--replay-hook)
			COMPREPLY=( $(compgen -W "pre_install post_install pre_upgrade post_upgrade pre_remove post_remove" -- "$cur") )
			return 0
			;;
	esac

	if [[ "$cur" == -* ]]; then
		COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
	else
		COMPREPLY=( $(compgen -W "$ops" -- "$cur") )
	fi
}
complete -F _paruz paruz
