#!/bin/bash
# Bash completion for odooctl.sh

_odooctl_instances() {
    local env_dir="/etc/odoo_deploy"
    local f
    local names=()
    if [ -d "$env_dir" ]; then
        for f in "$env_dir"/*.env; do
            [ -f "$f" ] || continue
            names+=("$(basename "$f" .env)")
        done
    fi
    printf '%s\n' "${names[@]}"
}

_odooctl_suffixes() {
    local env_dir="/etc/odoo_deploy"
    local f
    local names=()
    if [ -d "$env_dir" ]; then
        for f in "$env_dir"/prod*.env; do
            [ -f "$f" ] || continue
            names+=("$(basename "$f" .env | sed 's/^prod//')")
        done
    fi
    printf '%s\n' "${names[@]}" | awk '!seen[$0]++'
}

_odooctl_complete() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    local commands="deploy git-update modules backup-restore backup-restore-env shell venv mini-deploy describe help"

    # First argument: command
    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        return 0
    fi

    case "${COMP_WORDS[1]}" in
        deploy|modules|git-update)
            if [ "$COMP_CWORD" -eq 2 ]; then
                COMPREPLY=( $(compgen -W "$(_odooctl_instances)" -- "$cur") )
                return 0
            fi
            ;;
        backup-restore|backup-restore-env)
            if [ "$COMP_CWORD" -eq 2 ]; then
                COMPREPLY=( $(compgen -W "$(_odooctl_suffixes)" -- "$cur") )
                return 0
            fi
            ;;
        describe)
            if [ "$COMP_CWORD" -eq 2 ]; then
                COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
                return 0
            fi
            ;;
    esac

    # git-update subcommands
    if [ "${COMP_WORDS[1]}" = "git-update" ]; then
        if [ "$COMP_CWORD" -eq 3 ]; then
            COMPREPLY=( $(compgen -W "update" -- "$cur") )
            return 0
        fi
        if [ "$COMP_CWORD" -ge 4 ] && [ "${COMP_WORDS[2]}" = "update" ]; then
            COMPREPLY=( $(compgen -W "-all" -- "$cur") )
            return 0
        fi
    fi
}

complete -F _odooctl_complete odooctl.sh odooctl
