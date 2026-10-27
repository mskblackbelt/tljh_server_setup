#!/usr/bin/env bash
# Re-run under bash if started with `sh script`.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
#
# tljh-install-uv-ty - Install uv (Python package/project manager) and ty
# (Python type checker and language server) for every user of the server, and
# make ty the Python language server in JupyterLab. (Source:
# scripts/install_uv_ty.sh in the setup repo; tljh_server_setup.sh installs it
# to /usr/local/sbin.)
#
# Usage:
#   sudo tljh-install-uv-ty [options]
#
# Options:
#   --uv-version V   uv version to install (default 0.13.5), or "latest".
#   --ty-version V   ty version to install (default 0.0.92), or "latest".
#                    ty is pre-1.0 and changes quickly, so the defaults are
#                    pinned to versions that were tested here. "latest" asks
#                    GitHub which release is newest.
#   --prefix DIR     Install under DIR/bin (default /usr/local, which is on
#                    every user's PATH: notebooks, JupyterLab terminals, SSH).
#   --tljh-user DIR  The TLJH user environment that runs JupyterLab for
#                    everyone (default /opt/tljh/user).
#   --no-lsp         Install the programs only; don't touch JupyterLab.
#   --dry-run        Print what would be done without changing anything.
#   -h, --help       Show this help.
#
# What it does:
#   1. Downloads the uv and ty release archives from GitHub
#      (github.com/astral-sh/uv and /ty), checks each against the SHA-256 file
#      published beside it, and installs the programs (uv, uvx, ty) in
#      PREFIX/bin, owned by root and executable by everyone. A program that is
#      already at the requested version is left alone, so re-running is cheap.
#      Then it runs each one as an unprivileged user to prove it works.
#   2. Registers ty as the Python language server for every user's JupyterLab
#      by merging an entry into
#        TLJH_USER/etc/jupyter/jupyter_server_config.json
#      (other settings in that file are kept). It needs jupyterlab-lsp in the
#      TLJH user environment; environments/base_requirements.txt lists it, and
#      tljh_server_setup.sh installs that first. Users get ty the next time
#      their server starts (File > Hub Control Panel > Stop My Server, then
#      start it again); no hub reload is needed.
#
# Per-user state stays per user. uv's environments (.venv in a project), its
# package cache (~/.cache/uv), the Pythons it downloads
# (~/.local/share/uv/python) and `uv tool install` programs
# (~/.local/share/uv, ~/.local/bin) all live in the user's own home folder and
# count against the home quota. Nothing is shared or written under PREFIX
# except the programs themselves. `uv self update` does not work for a copy
# installed this way (nobody but root could write it, and there is no installer
# receipt); update by re-running this command.
#
# ty looks for third-party packages in the Python environment that the
# JupyterLab server itself runs in (/opt/tljh/user), not in the environment of
# the notebook's kernel. See docs/server_setup.md, "uv and ty".
#
# For a mirror of the GitHub release files (or for testing), set
#   ASTRAL_GITHUB_URL=https://mirror.example/astral-sh
# before running (it must contain uv/releases/download/<version>/... and
# ty/releases/download/<version>/...; use sudo --preserve-env or run as root).

set -euo pipefail
trap 'echo "error: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

UV_VERSION=0.13.5
TY_VERSION=0.0.92
PREFIX=/usr/local
TLJH_USER=/opt/tljh/user
DO_LSP=1
DRY_RUN=0
GITHUB_URL=${ASTRAL_GITHUB_URL:-https://github.com/astral-sh}
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

usage() { sed -n '5,/^$/s/^# \{0,1\}//p' "$0"; }
info() { printf '%s\n' "$*"; }
die()  { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --uv-version)  UV_VERSION=${2:?--uv-version needs a value}; shift 2 ;;
        --ty-version)  TY_VERSION=${2:?--ty-version needs a value}; shift 2 ;;
        --prefix)      PREFIX=${2:?--prefix needs a folder}; shift 2 ;;
        --tljh-user)   TLJH_USER=${2:?--tljh-user needs a folder}; shift 2 ;;
        --no-lsp)      DO_LSP=0; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage >&2; die "unknown option: $1" ;;
    esac
done

for v in "$UV_VERSION" "$TY_VERSION"; do
    [[ $v == latest || $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "'$v' is not a version like 0.13.5 (or 'latest')"
done
[[ $PREFIX == /* && $TLJH_USER == /* ]] || die "--prefix and --tljh-user must be absolute paths"

if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then
    die "run this as root: sudo tljh-install-uv-ty"
fi
for c in curl tar sha256sum install; do
    command -v "$c" >/dev/null || die "$c is required but not installed"
done

# --- Which release archive ------------------------------------------------------
# Ubuntu uses glibc, so the "gnu" builds are the right ones.
case $(uname -m) in
    x86_64)        ARCH=x86_64 ;;
    aarch64|arm64) ARCH=aarch64 ;;
    *)             die "no uv/ty release for CPU type $(uname -m)" ;;
esac
TARGET=$ARCH-unknown-linux-gnu

# latest_version <uv|ty>: the newest release's version number, from the
# redirect GitHub gives for /releases/latest (no API token or rate limit).
latest_version() {
    local url
    url=$(curl -fsSIL --proto '=https' --tlsv1.2 -o /dev/null -w '%{url_effective}' \
        "$GITHUB_URL/$1/releases/latest") || die "couldn't ask GitHub for the latest $1 release"
    url=${url##*/}
    [[ $url =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected latest-release address for $1: $url"
    printf '%s\n' "$url"
}

# installed_version <program>: "0.13.5" for `uv 0.13.5 (...)`, nothing if absent.
installed_version() {
    local bin=$PREFIX/bin/$1
    [[ -x $bin ]] || return 0
    "$bin" --version 2>/dev/null | awk '{print $2; exit}' || true
}

WORK=$(mktemp -d /tmp/tljh-uv-ty.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# install_tool <uv|ty> <version> <program>...: download, verify, install.
install_tool() {
    local tool=$1 version=$2; shift 2
    local programs=("$@")
    if [[ $version == latest ]]; then
        version=$(latest_version "$tool")
        info "Newest $tool release: $version"
    fi
    local have
    have=$(installed_version "$tool")
    if [[ $have == "$version" ]]; then
        info "$tool $version is already installed in $PREFIX/bin"
        return 0
    fi
    local name=$tool-$TARGET.tar.gz
    local url=$GITHUB_URL/$tool/releases/download/$version/$name
    if [[ $DRY_RUN -eq 1 ]]; then
        info "Would install $tool $version${have:+ (replacing $have)} from $url"
        return 0
    fi
    info "Installing $tool $version${have:+ (replacing $have)}"
    local dir=$WORK/$tool
    mkdir -p "$dir/unpacked"
    curl -fsSL --proto '=https,file' --tlsv1.2 --retry 3 -o "$dir/$name" "$url" \
        || die "couldn't download $url (is $version a real $tool release?)"
    curl -fsSL --proto '=https,file' --tlsv1.2 --retry 3 -o "$dir/$name.sha256" "$url.sha256" \
        || die "couldn't download $url.sha256"
    # The .sha256 file is "<hash> *<file name>"; compare the hash alone, so a
    # different file name inside it can't matter.
    local want got
    want=$(awk '{print tolower($1); exit}' "$dir/$name.sha256")
    got=$(sha256sum "$dir/$name" | awk '{print $1}')
    [[ $want =~ ^[0-9a-f]{64}$ ]] || die "$name.sha256 doesn't hold a SHA-256 hash"
    [[ $got == "$want" ]] || die "checksum mismatch for $name (expected $want, got $got); nothing installed"
    tar -xzf "$dir/$name" -C "$dir/unpacked"
    local p src
    for p in "${programs[@]}"; do
        src=$(find "$dir/unpacked" -type f -name "$p" | head -1)
        [[ -n $src ]] || die "$name has no '$p' program inside"
        # install(1) replaces the file by name, so a running copy keeps working.
        install -D -m 0755 -o root -g root "$src" "$PREFIX/bin/$p"
    done
    info "  installed ${programs[*]} in $PREFIX/bin"
}

install_tool uv "$UV_VERSION" uv uvx
install_tool ty "$TY_VERSION" ty

# Prove an ordinary user can run them (a root-only mode or a missing library
# would show up here, not weeks later in a student's terminal).
if [[ $DRY_RUN -eq 0 ]]; then
    for p in uv uvx ty; do
        ver=$(runuser -u nobody -- env -i PATH=/usr/bin:/bin HOME=/tmp "$PREFIX/bin/$p" --version) \
            || die "$PREFIX/bin/$p doesn't run as an unprivileged user"
        info "  $ver"
    done
fi

# --- ty as the language server in JupyterLab ---------------------------------------
# jupyter-lsp (the server half of jupyterlab-lsp) starts "ty server" when a
# user opens a Python file or notebook, and speaks LSP with it over stdio.
# jupyter-lsp doesn't know ty by itself, so it is declared here:
#   argv                         full path, so it doesn't depend on the PATH
#                                of the user's server
#   requires_documents_on_disk   false: ty reads notebook cells from memory.
#                                With true, JupyterLab writes copies of every
#                                open notebook's code into a .virtual_documents
#                                folder in the user's home.
# The entry goes into jupyter_server_config.json beside the other settings
# written by tljh_server_setup.sh (step 8); anything else in the file is kept.
if [[ $DO_LSP -eq 1 ]]; then
    server_cfg=$TLJH_USER/etc/jupyter/jupyter_server_config.json
    if [[ $DRY_RUN -eq 1 ]]; then
        info "Would add ty ($PREFIX/bin/ty server) to $server_cfg"
    else
        [[ -x $TLJH_USER/bin/python ]] || die "$TLJH_USER/bin/python not found; is TLJH installed? (use --no-lsp to skip JupyterLab)"
        "$TLJH_USER/bin/python" -c 'import jupyter_lsp, jupyterlab_lsp' 2>/dev/null \
            || die "jupyterlab-lsp is not installed in $TLJH_USER. Install it first:
  sudo -EH $TLJH_USER/bin/python -m pip install -r <repo>/environments/base_requirements.txt"
        install -d -m 0755 "$(dirname "$server_cfg")"
        "$TLJH_USER/bin/python" - "$server_cfg" "$PREFIX/bin/ty" <<'PY'
import json, os, sys
path, ty = sys.argv[1], sys.argv[2]
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        cfg = json.load(f)
servers = cfg.setdefault("LanguageServerManager", {}).setdefault("language_servers", {})
servers["ty"] = {
    "version": 2,
    "display_name": "ty",
    "argv": [ty, "server"],
    "languages": ["python"],
    "mime_types": ["text/x-python", "application/x-python-code"],
    "requires_documents_on_disk": False,
}
tmp = path + ".new"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print("Updated", path)
PY
        chmod 0644 "$server_cfg"
        info "ty will be the Python language server the next time each user's server starts."
    fi
fi

info "Done."
