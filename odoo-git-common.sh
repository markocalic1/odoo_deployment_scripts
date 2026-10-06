#!/bin/bash
# Caller provides run_repo_git and sets the repository as the working directory.

check_repo_submodules_clean() {
    run_repo_git submodule foreach --recursive '
        if test -n "$(git status --porcelain)"; then
            echo "Submodul ima lokalne izmjene: $displaypath" >&2
            exit 1
        fi
    '
}

sync_repo_submodules() {
    run_repo_git submodule sync --recursive || return $?
    run_repo_git submodule update --init --recursive --checkout
}

restore_repo_commit() {
    # Deinit removes clean checkouts, including submodules absent in the old commit.
    # Keep cached repositories in .git/modules and refuse to discard local edits.
    run_repo_git submodule deinit --all || return $?
    run_repo_git reset --hard "$1" || return $?
    sync_repo_submodules
}
