#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: $0 <command> [args...]

Commands:
  deploy <instance>                     Safe deploy: backup DB/code, git reset, pip install, restart, health check, rollback
  git-update <instance> [update ...]    Git update with stash/backup/checks; optional module update
  modules <instance> <m1,m2>            Update modules on a DB (no deploy)
  backup-restore <suffix>               Production -> staging sync (DB + filestore) wrapper
  backup-restore-env <suffix>           Create prod/staging env files for backup-restore
  shell                                 Launch Odoo shell (auto-detect service/config)
  venv                                  Activate Odoo venv (defaults to /opt/odoo)
  mini-deploy                           Minimal deploy: git pull + pip install + restart (no backup/rollback)
  describe <command>                    Show detailed info for one command
  help                                  Show this help (detailed)

Examples:
  $0 deploy staging19
  $0 git-update staging19 update -all
  $0 modules staging19 sale,stock,account
  $0 backup-restore 19
  $0 backup-restore-env 19
  $0 describe deploy
  $0 --help staging19
EOF
}

describe_command() {
    case "$1" in
        deploy)
            echo "deploy: Safe deploy (backup DB/code, git reset to origin/<branch>, pip install, restart, health check, auto-rollback)."
            echo "  Uses: /etc/odoo_deploy/<instance>.env (DB_NAME, DB_USER, DB_HOST, DB_PORT, OE_HOME, OE_USER, BRANCH, SERVICE_NAME, ODOO_PORT)"
            ;;
        git-update)
            echo "git-update: Git update with stash/restore, DB backup, requirements diff, syntax check; optional module update."
            echo "  Uses: /etc/odoo_deploy/<instance>.env (OE_HOME, OE_USER, BRANCH, DB_NAME, SERVICE_NAME)"
            echo "  Reads: /etc/systemd/system/<service>.service to detect -c config path"
            ;;
        modules)
            echo "modules: Update Odoo modules using odoo-bin -u (stops/starts service)."
            echo "  Uses: /etc/odoo_deploy/<instance>.env (DB_NAME, OE_HOME, OE_USER, SERVICE_NAME)"
            echo "  Reads: /etc/systemd/system/<service>.service to detect -c config path"
            ;;
        backup-restore)
            echo "backup-restore: Production -> staging sync (backup on prod, download, restore DB + filestore)."
            echo "  Uses: /etc/odoo_deploy/prod<suffix>.env + /etc/odoo_deploy/staging<suffix>.env"
            echo "  Optional: /etc/odoo_deploy/odoo-sync.env (master passwords, defaults)"
            ;;
        backup-restore-env)
            echo "backup-restore-env: Create prod/staging env files from existing instance envs."
            echo "  Reads: /etc/odoo_deploy/<instance>.env"
            echo "  Writes: /etc/odoo_deploy/prod<suffix>.env and /etc/odoo_deploy/staging<suffix>.env"
            ;;
        shell)
            echo "shell: Launch Odoo interactive shell using detected systemd service config."
            echo "  Reads: /etc/systemd/system/<service>.service to detect -c config path"
            ;;
        venv)
            echo "venv: Activate Odoo virtualenv at /opt/odoo/venv (edit script if different)."
            ;;
        mini-deploy)
            echo "mini-deploy: Minimal deploy (git pull, pip install if requirements.txt exists, restart service)."
            echo "  Uses hardcoded paths in odoo_deploy_mini.sh (ODOO_HOME/SRC_DIR/ODOO_SERVICE)."
            ;;
        *)
            echo "Unknown command: $1"
            ;;
    esac
}

show_instance_details() {
    local instance="$1"
    local env_file="/etc/odoo_deploy/${instance}.env"
    local service=""
    local service_file=""
    local config_path=""

    echo ""
    echo "Instance details:"
    if [ -f "$env_file" ]; then
        # shellcheck disable=SC1090
        source "$env_file"
        echo "  ENV:        $env_file"
        [ -n "$OE_HOME" ] && echo "  OE_HOME:    $OE_HOME"
        [ -n "$OE_USER" ] && echo "  OE_USER:    $OE_USER"
        [ -n "$BRANCH" ] && echo "  BRANCH:     $BRANCH"
        [ -n "$DB_NAME" ] && echo "  DB_NAME:    $DB_NAME"
        service="${SERVICE_NAME:-odoo}"
        echo "  SERVICE:    $service"
        service_file="/etc/systemd/system/${service}.service"
        echo "  SERVICE_FILE: $service_file"
        if [ -f "$service_file" ]; then
            config_path=$(grep -oP '(?<=-c ).+' "$service_file" | tr -d ' ')
            [ -n "$config_path" ] && echo "  ODOO_CONFIG: $config_path"
        fi
    else
        echo "  ENV:        $env_file (missing)"
    fi
}

run_root() {
    if [ "$EUID" -ne 0 ]; then
        sudo bash "$@"
    else
        bash "$@"
    fi
}

COMMAND="$1"
if [ -z "$COMMAND" ]; then
    usage
    exit 1
fi
shift

case "$COMMAND" in
    deploy)
        run_root "$SCRIPT_DIR/deploy_odoo.sh" "$@"
        ;;
    git-update)
        run_root "$SCRIPT_DIR/odoo-git-update.sh" "$@"
        ;;
    modules)
        run_root "$SCRIPT_DIR/odoo-update-modules.sh" "$@"
        ;;
        backup-restore)
        run_root "$SCRIPT_DIR/odoo-backup-restore.sh" "$@"
        ;;
    backup-restore-env)
        run_root "$SCRIPT_DIR/odoo-sync-env-create.sh" "$@"
        ;;
    shell)
        bash "$SCRIPT_DIR/odoo-shell.sh" "$@"
        ;;
    venv)
        bash "$SCRIPT_DIR/odoo-venv.sh" "$@"
        ;;
    mini-deploy)
        run_root "$SCRIPT_DIR/odoo_deploy_mini.sh" "$@"
        ;;
    describe)
        if [ -z "$1" ]; then
            echo "Usage: $0 describe <command>"
            exit 1
        fi
        describe_command "$1"
        ;;
    help|-h|--help)
        usage
        echo ""
        echo "Details:"
        describe_command deploy
        describe_command git-update
        describe_command modules
        describe_command backup-restore
        describe_command shell
        describe_command venv
        describe_command mini-deploy
        if [ -n "$1" ]; then
            show_instance_details "$1"
        fi
        ;;
    *)
        echo "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
