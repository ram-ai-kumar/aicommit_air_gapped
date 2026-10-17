# Bash completion for aicommit
_aicommit_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local opts="--help --dry-run --verbose --regenerate --clean-cache --yes --split --no-split --all --bump --semver --tag --no-tag -h -d -v -r -y -s -b"
    COMPREPLY=($(compgen -W "$opts" -- "$cur"))
}

_aisemver_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local opts="--help --dry-run --yes --auto --major --minor --patch --set= --message= --tag --no-tag --commit --no-commit --stage --no-stage --changelog --no-changelog -h -d -y -m major minor patch auto"
    COMPREPLY=($(compgen -W "$opts" -- "$cur"))
}

complete -F _aicommit_completions aicommit aic aicc aicx aiccx aics aiccs aicsx aiccsx
complete -F _aisemver_completions ais aisemver aisx
