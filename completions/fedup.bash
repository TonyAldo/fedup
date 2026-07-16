# bash completion for fedup — install via: fedup --install-completion
# or: cp completions/fedup.bash ~/.local/share/bash-completion/completions/fedup

_fedup() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="--all --security --check --notify --json --dry-run --remote --remote-check --offline --self-update --install-completion --doctor --whiptail --version --help -h"
    case "$prev" in
        --remote|--remote-check)
            COMPREPLY=( $(compgen -A hostname -- "$cur") )
            return 0;;
        --dry-run)
            COMPREPLY=( $(compgen -W "--all --security --check --offline --remote" -- "$cur") )
            return 0;;
    esac
    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    fi
}
complete -F _fedup fedup fedup.sh
