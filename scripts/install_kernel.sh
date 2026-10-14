#!/usr/bin/env bash
#
# tljh-install-kernel - Build a conda environment from a dependency file and
# register it as a Jupyter kernel that every user on this TLJH hub can pick
# from the JupyterLab kernel menu.
#
# Usage:
#   sudo -E tljh-install-kernel [options] <dependency-file>
#   sudo -E tljh-install-kernel --remove <env-name>
#
# Admins only. (Source: scripts/install_kernel.sh in the setup repo;
# tljh_server_setup.sh installs it to /usr/local/sbin.)
#
# <dependency-file> can be any of:
#   yaml   A conda/mamba environment file (.yml/.yaml). May include channels
#          and a `pip:` section. The env name comes from its `name:` key.
#   pip    A pip requirements file (requirements.txt style: `pkg==1.2`,
#          `-r other.txt`, `git+https://...`). A fresh conda env is built
#          with python + pip + ipykernel, then `pip install -r` is run in it.
#   conda  A conda package list, as written by `conda list --export` or
#          `conda list --explicit`.
# The format is guessed from the file (extension, then contents); use
# --format to override the guess.
#
# Options:
#   -n, --name NAME          Env/kernel name. Required unless the YAML file
#                            has a `name:` key. Allowed: lowercase letters,
#                            digits . _ -
#   -d, --display-name TEXT  Label in the kernel menu (default: "Python (NAME)")
#   -f, --format FORMAT      yaml | pip | conda (overrides the guess)
#   -p, --python VERSION     Python version for pip-format envs, e.g. 3.13
#   -r, --recreate           Delete and rebuild the env from scratch. Use this
#                            when you REMOVE packages from a file; a normal
#                            re-run only adds/upgrades.
#       --remove             Unregister the kernel and delete the env.
#       --dry-run            Print the commands without running them.
#   -h, --help               Show this help.
#
# Examples:
#   sudo -E tljh-install-kernel environments/pchem2_env.yaml
#   sudo -E tljh-install-kernel -r environments/pchem2_env.yaml
#   sudo -E tljh-install-kernel -n stats101 -p 3.13 -d "Python (Stats 101)" requirements.txt
#   sudo -E tljh-install-kernel --remove pchem2
#
# Notes:
#   * Environments go in /opt/tljh/user/envs/<name>. Kernelspecs go in
#     /opt/tljh/user/share/jupyter/kernels/<name>. JupyterLab itself always
#     runs from /opt/tljh/user; this env only needs ipykernel.
#   * Plain `sudo` works too. `sudo -E` is only needed to pass through things
#     like proxy settings. The script clears the other variables `-E` carries
#     over (see "Sanitize the environment" below).
#   * Students see the new kernel after they reload JupyterLab. No hub
#     restart is required.

# Re-run under bash if started with `sh script` (dash on Ubuntu ignores the
# shebang line and can't run bash-only syntax such as {a,b} or [[ ]]).
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

set -euo pipefail
trap 'echo "error: command failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# --- Fixed locations -------------------------------------------------------

TLJH_USER_PREFIX=/opt/tljh/user
MAMBA_BIN="$TLJH_USER_PREFIX/bin/mamba"
CONDA_BIN="$TLJH_USER_PREFIX/bin/conda"
JUPYTER_BIN="$TLJH_USER_PREFIX/bin/jupyter"
KERNEL_DIR="$TLJH_USER_PREFIX/share/jupyter/kernels"

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; }
die()   { echo "error: $*" >&2; exit 1; }
info()  { echo "==> $*"; }

# Run a command, or only print it with --dry-run.
run() {
    printf '    $'; printf ' %q' "$@"; printf '\n'
    if [[ $DRY_RUN -eq 0 ]]; then "$@"; fi
}

# --- Sanitize the environment ----------------------------------------------
#
# `sudo -E` keeps the admin's whole environment. Several variables in it
# can quietly break a shared install:
#   HOME    Conda, mamba and pip would write root-owned caches and
#           ~/.conda/environments.txt into the admin's home directory. Pip
#           would also read the admin's ~/.local site-packages and decide
#           packages are "already installed" when students can't see them.
#   umask   A private umask (e.g. 077) would make the new env unreadable to
#           students. sudo can keep the stricter of the two umasks.
#   CONDA_*, MAMBA_*, PYTHON*, PIP_*  An active conda env, a personal
#           MAMBA_ROOT_PREFIX, PIP_USER=1 and the like can redirect installs.
# Proxy variables (http_proxy etc.) are left alone on purpose, since they
# are the usual reason to use -E.

export PATH="$TLJH_USER_PREFIX/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
HOME=$(getent passwd root | cut -d: -f6); export HOME
umask 0022

for var in $(compgen -e); do
    case "$var" in
        CONDA_*|MAMBA_*|PIP_*|PYTHON*|VIRTUAL_ENV|XDG_CACHE_HOME|XDG_CONFIG_HOME|CONDARC|MAMBARC)
            unset "$var" ;;
    esac
done

export PYTHONNOUSERSITE=1        # never see anyone's ~/.local site-packages
export PIP_ROOT_USER_ACTION=ignore
export CONDA_ALWAYS_YES=true MAMBA_ALWAYS_YES=true   # non-interactive, any mamba version

# --- Parse arguments -------------------------------------------------------

ENV_NAME="" DISPLAY_NAME="" FORMAT="" PY_VERSION=""
RECREATE=0 REMOVE=0 DRY_RUN=0 DEP_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name)         ENV_NAME=${2:?"$1 needs a value"}; shift 2 ;;
        -d|--display-name) DISPLAY_NAME=${2:?"$1 needs a value"}; shift 2 ;;
        -f|--format)       FORMAT=${2:?"$1 needs a value"}; shift 2 ;;
        -p|--python)       PY_VERSION=${2:?"$1 needs a value"}; shift 2 ;;
        -r|--recreate)     RECREATE=1; shift ;;
        --remove)          REMOVE=1; shift ;;
        --dry-run)         DRY_RUN=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        --)                shift; break ;;
        -*)                usage >&2; die "unknown option: $1" ;;
        *)                 break ;;
    esac
done

if [[ $REMOVE -eq 1 ]]; then
    [[ $# -eq 1 ]] || { usage >&2; die "--remove takes exactly one env name"; }
    ENV_NAME=${ENV_NAME:-$1}
else
    [[ $# -eq 1 ]] || { usage >&2; die "expected exactly one dependency file"; }
    DEP_FILE=$(realpath -e -- "$1") || die "dependency file not found: $1"
fi

# --- Preflight checks ------------------------------------------------------

if [[ $DRY_RUN -eq 0 ]]; then
    [[ $EUID -eq 0 ]] || die "this writes to $TLJH_USER_PREFIX; run it with sudo -E"
    for bin in "$MAMBA_BIN" "$CONDA_BIN" "$JUPYTER_BIN"; do
        [[ -x "$bin" ]] || die "$bin not found. Is TLJH installed on this server?"
    done
fi

# --- Work out the format and the env name ------------------------------------

if [[ $REMOVE -eq 0 && -z "$FORMAT" ]]; then
    case "$DEP_FILE" in
        *.yml|*.yaml) FORMAT=yaml ;;
        *)
            # conda list --export / --explicit always write one of these headers.
            if grep -qE '^(@EXPLICIT|# platform:)' "$DEP_FILE"; then
                FORMAT=conda
            else
                FORMAT=pip
            fi ;;
    esac
fi

case "${FORMAT:-remove}" in
    yaml|pip|conda|remove) ;;
    *) die "unknown --format '$FORMAT' (expected yaml, pip or conda)" ;;
esac

if [[ -z "$ENV_NAME" && "$FORMAT" == yaml ]]; then
    # Read `name:` without needing a YAML parser. `|| true` stops set -e/pipefail
    # from killing the script silently when the file has no name key.
    ENV_NAME=$(grep -m1 -E '^name:' "$DEP_FILE" \
        | sed -E "s/^name:[[:space:]]*//; s/[[:space:]]*(#.*)?$//; s/^[\"'](.*)[\"']$/\1/" \
        || true)
fi

[[ -n "$ENV_NAME" ]] || die "no environment name. Pass -n NAME (required for pip/conda files)."
# Jupyter lowercases kernel names, so require lowercase to keep the env
# name and kernel name identical.
[[ "$ENV_NAME" =~ ^[a-z0-9._-]+$ ]] \
    || die "invalid name '$ENV_NAME' (use lowercase letters, digits, '.', '_' or '-')"
case "$ENV_NAME" in
    base|root|.|..) die "'$ENV_NAME' is reserved; choose another name" ;;
esac
[[ -z "$PY_VERSION" || "$FORMAT" == pip ]] \
    || die "--python only applies to pip requirements files; set python in the $FORMAT file instead"

ENV_PREFIX="$TLJH_USER_PREFIX/envs/$ENV_NAME"
DISPLAY_NAME=${DISPLAY_NAME:-"Python ($ENV_NAME)"}

# --- Remove mode -------------------------------------------------------------

if [[ $REMOVE -eq 1 ]]; then
    info "Removing kernel and environment '$ENV_NAME'"
    if [[ -d "$KERNEL_DIR/$ENV_NAME" ]]; then
        run "$JUPYTER_BIN" kernelspec remove -f "$ENV_NAME"
    else
        info "No kernelspec at $KERNEL_DIR/$ENV_NAME; skipping"
    fi
    if [[ -d "$ENV_PREFIX" ]]; then
        run "$CONDA_BIN" remove -p "$ENV_PREFIX" --all -y
    else
        info "No environment at $ENV_PREFIX; skipping"
    fi
    info "Done."
    exit 0
fi

# --- Build or update the environment -------------------------------------------

info "Env name     : $ENV_NAME"
info "Kernel label : $DISPLAY_NAME"
info "Source file  : $DEP_FILE ($FORMAT)"
info "Env prefix   : $ENV_PREFIX"
info "Invoked by   : ${SUDO_USER:-$(id -un)}"

# Run from the file's own folder so relative paths inside it (`-r other.txt`,
# `-e ./pkg`, relative files in a YAML pip section) resolve as intended.
cd "$(dirname "$DEP_FILE")"

if [[ $RECREATE -eq 1 && -d "$ENV_PREFIX" ]]; then
    info "--recreate: deleting the existing environment first"
    run "$CONDA_BIN" remove -p "$ENV_PREFIX" --all -y
fi

EXISTS=0; [[ -d "$ENV_PREFIX/conda-meta" ]] && EXISTS=1
CF=(--override-channels -c conda-forge)   # match the YAML files' conda-forge/nodefaults choice

case "$FORMAT:$EXISTS" in
    yaml:0)
        info "Creating environment from YAML"
        run "$MAMBA_BIN" env create -p "$ENV_PREFIX" -f "$DEP_FILE" ;;
    yaml:1)
        # No --prune: it is unreliable in mamba 2.x (mamba-org/mamba#3174).
        # Use --recreate to drop packages that were removed from the file.
        info "Updating existing environment from YAML (adds/upgrades only; use -r to drop removed packages)"
        run "$MAMBA_BIN" env update -p "$ENV_PREFIX" -f "$DEP_FILE" ;;
    conda:0)
        info "Creating environment from conda package list"
        run "$MAMBA_BIN" create -p "$ENV_PREFIX" "${CF[@]}" --file "$DEP_FILE" -y ;;
    conda:1)
        info "Updating existing environment from conda package list"
        run "$MAMBA_BIN" install -p "$ENV_PREFIX" "${CF[@]}" --file "$DEP_FILE" -y ;;
    pip:0)
        info "Creating base environment for pip requirements"
        run "$MAMBA_BIN" create -p "$ENV_PREFIX" "${CF[@]}" -y \
            "python${PY_VERSION:+=$PY_VERSION}" pip ipykernel ;;
    pip:1)
        [[ -z "$PY_VERSION" ]] || info "Env already exists; --python ignored (use -r to change it)" ;;
esac

if [[ "$FORMAT" == pip ]]; then
    info "Installing pip requirements"
    run "$ENV_PREFIX/bin/python" -m pip install -r "$DEP_FILE"
fi

# --- Make sure it can run as a kernel -------------------------------------------
# Only ipykernel is needed here. JupyterLab and widget front-ends such as
# jupyterlab_widgets belong in the base env (/opt/tljh/user).

if [[ $DRY_RUN -eq 1 ]] || ! "$ENV_PREFIX/bin/python" -c 'import ipykernel' 2>/dev/null; then
    info "Ensuring ipykernel is installed"
    run "$MAMBA_BIN" install -p "$ENV_PREFIX" "${CF[@]}" -y ipykernel
fi

# --- Register the kernel -----------------------------------------------------------
# --prefix is the TLJH user env itself, which puts the spec in
# $KERNEL_DIR/<name>, where the hub's JupyterLab looks for kernels.

if [[ -f "$KERNEL_DIR/$ENV_NAME/kernel.json" ]] \
   && ! grep -qF "$ENV_PREFIX/" "$KERNEL_DIR/$ENV_NAME/kernel.json"; then
    echo "warning: kernel '$ENV_NAME' already exists and points somewhere else; overwriting it" >&2
fi

info "Registering kernel"
run "$ENV_PREFIX/bin/python" -m ipykernel install \
    --name "$ENV_NAME" --display-name "$DISPLAY_NAME" --prefix "$TLJH_USER_PREFIX"

# --- Verify from the hub's point of view -----------------------------------------

if [[ $DRY_RUN -eq 0 ]]; then
    "$JUPYTER_BIN" kernelspec list | awk -v n="$ENV_NAME" '$1==n{f=1} END{exit !f}' \
        || die "kernel was installed but the hub's jupyter does not list it"
    # Check that an ordinary account can use the env (catches permission problems).
    if id nobody >/dev/null 2>&1; then
        runuser -u nobody -- "$ENV_PREFIX/bin/python" -c 'import ipykernel' \
            || die "the env is not readable by non-root users; check permissions on $ENV_PREFIX"
    fi
fi

info "Done. \"$DISPLAY_NAME\" appears in the kernel menu after users reload JupyterLab."
