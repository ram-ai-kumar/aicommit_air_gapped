# Bash completion for aicommit
_aicommit_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local opts="--help --dry-run --verbose --regenerate --clean-cache --yes --split --no-split --all --bump --semver --tag --no-tag -h -d -v -r -y -s -b"
    COMPREPLY=($(compgen -W "$opts" -- "$cur"))
}

complete -F _aicommit_completions aicommit aic aicc aicx aiccx aics aiccs aicsx aiccsx
