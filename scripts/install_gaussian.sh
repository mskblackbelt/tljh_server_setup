#!/usr/bin/env bash
# Re-run under bash if started with `sh script`.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
#
# tljh-install-gaussian - Install (or replace) a Gaussian 16 binary
# distribution so every JupyterHub user can run it from notebooks, the
# JupyterLab terminal, and SSH. (Source: scripts/install_gaussian.sh in the
# setup repo; tljh_server_setup.sh installs it to /usr/local/sbin.)
#
# Usage:
#   sudo tljh-install-gaussian [options] <gaussian-files>
#
#   <gaussian-files>  The Gaussian 16 binary distribution, either
#                     - a folder holding the g16 files (g16, l1.exe, bsd/,
#                       ...), whatever it is named (e.g. g16_b01), or
#                     - an archive (.zip, .tgz, .tar.gz, .tbz, .tar.bz2,
#                       .tar.xz, .tar) holding that folder, at any depth and
#                       under any name (e.g. AVX2.zip from Gaussian).
#
# Options:
#   --scratch DIR   Scratch folder for Gaussian's temporary files
#                   (default /scratch/g16). Ideally its own ZFS dataset with
#                   no snapshots and a quota.
#   --mem SIZE      Default memory for jobs without %mem (default 6GB).
#   --nproc N       Default processor count for jobs without %nproc/%cpu
#                   (default 4). On the hub, resource_groups.py replaces
#                   both with each server's own limits; these values still
#                   apply to SSH logins.
#   --no-reload     Don't restart the hub at the end (tljh_server_setup.sh
#                   reloads it itself).
#   --dry-run       Print the commands without running them.
#   -h, --help      Show this help.
#
# What it does:
#   1. Installs tcsh (Gaussian's own scripts need it).
#   2. Copies the files to /opt/gaussian/g16 (g16root=/opt/gaussian). A
#      previous install is kept as /opt/gaussian/g16.previous.
#   3. Makes them owned by root and the jupyterhub-users group, readable and
#      executable by that group only, then runs Gaussian's bsd/install (which
#      removes access for everyone else, as Gaussian's license expects).
#      TLJH puts every hub account in jupyterhub-users, so every user can run
#      Gaussian with no per-user steps.
#   4. Creates the shared scratch folder and a daily cleanup rule for
#      leftover scratch files older than 7 days.
#   5. Sets Gaussian's environment for every user's server (notebooks and
#      JupyterLab terminals) and for SSH logins.
#   6. Runs Gaussian's test job 0 as a non-root member of jupyterhub-users
#      and compares the energy with Gaussian's reference output.
#
# Non-hub Linux accounts (e.g. an admin's own SSH login) need adding once:
#   sudo usermod -aG jupyterhub-users <account>

set -euo pipefail
trap 'echo "error: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

G16ROOT=/opt/gaussian
GROUP=jupyterhub-users
SCRATCH=/scratch/g16
MEM_DEFAULT=6GB
NPROC_DEFAULT=4
HUB_SNIPPET=/opt/tljh/config/jupyterhub_config.d/gaussian.py
PROFILE_SNIPPET=/etc/profile.d/gaussian.sh
TMPFILES_RULE=/etc/tmpfiles.d/gaussian-scratch.conf
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

usage() { sed -n '5,/^$/s/^# \{0,1\}//p' "$0"; }
die()   { echo "error: $*" >&2; exit 1; }
info()  { echo "==> $*"; }
run()   { printf '  $'; printf ' %q' "$@"; printf '\n'; if [[ $DRY_RUN -eq 0 ]]; then "$@"; fi; }

DRY_RUN=0 RELOAD=1 SRC=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scratch)   SCRATCH=${2:?"--scratch needs a folder"}; shift 2 ;;
        --mem)       MEM_DEFAULT=${2:?"--mem needs a size, e.g. 6GB"}; shift 2 ;;
        --nproc)     NPROC_DEFAULT=${2:?"--nproc needs a number"}; shift 2 ;;
        --no-reload) RELOAD=0; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        -*)          die "unknown option: $1 (see --help)" ;;
        *)           [[ -z "$SRC" ]] || die "expected one <gaussian-files> argument (see --help)"
                     SRC=$1; shift ;;
    esac
done
[[ -n "$SRC" ]] || die "expected one <gaussian-files> argument (see --help)"

# --- Checks ------------------------------------------------------------------------

[[ $DRY_RUN -eq 1 || $EUID -eq 0 ]] || die "run with sudo"
[[ "$(uname -m)" == x86_64 ]] || die "Gaussian 16 Linux binaries need an x86-64 machine"
[[ "$SCRATCH" == /* && "$SCRATCH" != / ]] || die "--scratch must be an absolute path"
[[ "$MEM_DEFAULT" =~ ^[0-9]+([KkMmGg][BbWw])?$ ]] || die "--mem looks wrong: $MEM_DEFAULT (e.g. 6GB)"
[[ "$NPROC_DEFAULT" =~ ^[1-9][0-9]*$ ]] || die "--nproc must be a positive number"
getent group "$GROUP" >/dev/null || die "group $GROUP not found; install TLJH first"
SRC=$(realpath -e -- "$SRC" 2>/dev/null) || die "not found: $SRC"

# --- 1. tcsh (and unzip for .zip files) ------------------------------------------------

if ! command -v tcsh >/dev/null; then
    info "Installing tcsh (needed by Gaussian's scripts)"
    run apt-get install -y tcsh
fi
if [[ "${SRC,,}" == *.zip ]] && ! command -v unzip >/dev/null; then
    info "Installing unzip"
    run apt-get install -y unzip
fi

# --- 2. Unpack into a staging folder, then swap into place ---------------------------
# Staging lives next to the final location, as .staging/g16, because
# Gaussian's bsd/install refuses to run unless its folder is named g16.

STAGE="$G16ROOT/.staging"
run install -d -m 0755 -o root -g root "$G16ROOT"
[[ $DRY_RUN -eq 1 ]] || rm -rf -- "${STAGE:?}"
run install -d -m 0700 -o root -g root "$STAGE"

if [[ -d "$SRC" ]]; then
    info "Copying Gaussian files from folder $SRC"
    if [[ -f "$SRC/g16/g16" && ! -f "$SRC/g16" ]]; then
        SRC="$SRC/g16"     # a folder that contains g16/
    fi
    [[ -f "$SRC/g16" && -f "$SRC/l1.exe" && -f "$SRC/bsd/g16.profile" ]] \
        || die "$SRC doesn't look like a Gaussian 16 folder (expected g16, l1.exe, bsd/g16.profile)"
    run cp -R --no-preserve=ownership -- "$SRC" "$STAGE/g16"
else
    info "Unpacking Gaussian archive $SRC"
    run install -d -m 0700 -o root -g root "$STAGE/unpack"
    case "${SRC,,}" in
        *.zip) run unzip -q "$SRC" -d "$STAGE/unpack" ;;
        *.tgz|*.tar.gz|*.tbz|*.tbz2|*.tar.bz2|*.txz|*.tar.xz|*.tar)
               run tar -xf "$SRC" -C "$STAGE/unpack" --no-same-owner ;;
        *) die "unrecognized archive type: $SRC (expected .zip, .tgz, .tar.gz, .tbz, .tar.bz2, .tar.xz or .tar)" ;;
    esac
    if [[ $DRY_RUN -eq 0 ]]; then
        # The Gaussian folder is whichever folder holds both g16 and l1.exe,
        # whatever it's called and however deep (zips made on a Mac add a
        # __MACOSX folder, which is skipped). It is renamed to g16, because
        # bsd/install only runs in a folder of that name.
        mapfile -t found < <(find "$STAGE/unpack" -maxdepth 4 -path '*/__MACOSX' -prune -o \
            -type f -name l1.exe -printf '%h\n' | while IFS= read -r d; do
                [[ -f "$d/g16" ]] && printf '%s\n' "$d"; done)
        [[ ${#found[@]} -eq 1 ]] \
            || die "expected one folder with g16 and l1.exe in the archive, found ${#found[@]}"
        mv -- "${found[0]}" "$STAGE/g16"
        rm -rf -- "${STAGE:?}/unpack"
        [[ -f "$STAGE/g16/bsd/g16.profile" ]] \
            || die "the Gaussian folder in the archive has no bsd/g16.profile"
    fi
fi

if [[ $DRY_RUN -eq 0 ]]; then
    NEW="$STAGE/g16"
    # Remove Mac / cloud-sync clutter.
    find "$NEW" \( -name .DS_Store -o -name '._*' \) -type f -delete

    # Report which CPU build this is, and check this CPU can run it.
    build=generic
    for f in haswell sandy sandybridge nehalem em64t; do
        [[ -e "$NEW/$f.flag" ]] && { build=$f; break; }
    done
    info "Gaussian build: $build ($(head -c 200 "$NEW/bsd/release_"*.txt 2>/dev/null | grep -m1 -o 'Rev[^ ]* [A-Z]\.[0-9]*' || echo 'revision unknown'))"
    case "$build" in
        haswell)          need=avx2 ;;
        sandy|sandybridge) need=avx ;;
        nehalem)          need=sse4_2 ;;
        *)                need="" ;;
    esac
    if [[ -n "$need" ]] && ! grep -qw "$need" /proc/cpuinfo; then
        die "this CPU lacks $need, which the $build build requires"
    fi

    # Ownership and permissions: root owns, the group can read and run,
    # nobody else gets anything. Files that are programs or scripts (ELF or
    # #!) become 750, everything else 640; this does not rely on execute
    # bits surviving the copy from OneDrive/macOS.
    chown -R root:"$GROUP" "$NEW"
    find "$NEW" -type d -exec chmod 0750 {} +
    find "$NEW" -type f -print0 | while IFS= read -r -d '' f; do
        magic=$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')
        case "$magic" in
            7f454c46|2321*) chmod 0750 "$f" ;;   # ELF binary or #! script
            *)              chmod 0640 "$f" ;;
        esac
    done
fi

info "Running Gaussian's bsd/install"
if [[ $DRY_RUN -eq 0 ]]; then
    ( cd "$STAGE/g16" && tcsh -f bsd/install )
else
    echo "  \$ (cd $STAGE/g16 && tcsh -f bsd/install)"
fi

info "Moving the new files into place at $G16ROOT/g16"
if [[ -d "$G16ROOT/g16" ]]; then
    [[ $DRY_RUN -eq 1 ]] || rm -rf -- "${G16ROOT:?}/g16.previous"
    run mv -- "$G16ROOT/g16" "$G16ROOT/g16.previous"
    echo "  (previous install kept as $G16ROOT/g16.previous; delete it once the new one works)"
fi
run mv -- "$STAGE/g16" "$G16ROOT/g16"
[[ $DRY_RUN -eq 1 ]] || rm -rf -- "${STAGE:?}"

# --- 4. Scratch folder and cleanup -------------------------------------------------------
# 3770: group members can create files; the sticky bit stops them deleting
# each other's; setgid keeps files in the group; others get nothing.
# Gaussian deletes its scratch files when a job ends normally; the tmpfiles
# rule removes leftovers from crashed or killed jobs after 7 days.

info "Scratch folder $SCRATCH"
run install -d -m 3770 -o root -g "$GROUP" "$SCRATCH"
run chmod 3770 "$SCRATCH"
if [[ $DRY_RUN -eq 0 ]]; then
    printf '# Installed by tljh-install-gaussian: Gaussian scratch folder; remove\n# leftover files older than 7 days (systemd-tmpfiles-clean runs daily).\nd %s 3770 root %s 7d\n' \
        "$SCRATCH" "$GROUP" > "$TMPFILES_RULE"
    chmod 0644 "$TMPFILES_RULE"
    systemd-tmpfiles --create "$TMPFILES_RULE"
else
    echo "  (would write $TMPFILES_RULE: d $SCRATCH 3770 root $GROUP 7d)"
fi

# --- 5. Environment ----------------------------------------------------------------------
# Notebooks and JupyterLab terminals inherit the environment the hub starts
# each user's server with, so the variables go into a JupyterHub config file
# (TLJH loads jupyterhub_config.d/*.py). These mirror bsd/g16.profile, with
# two deliberate differences:
#   * PATH is APPENDED to, as g16.profile does: Gaussian's bsd/ folder has
#     commands named `at`, `comp`, `dom`, ... that must not hide the system's.
#   * PYTHONPATH/PERLLIB/LD_LIBRARY_PATH are left alone: this distribution
#     has no GauOpen, Linda or shared libraries, and adding them would
#     clutter every Python kernel.
# GAUSS_MDEF/GAUSS_PDEF are defaults for jobs that don't set %mem/%nproc.
# GAUSS_PDEF (a count) is used rather than GAUSS_CDEF (a CPU list) so that
# jobs from different users aren't all pinned to the same cores.

info "Hub environment ($HUB_SNIPPET)"
if [[ $DRY_RUN -eq 0 ]]; then
    install -d -m 0755 "$(dirname "$HUB_SNIPPET")"
    cat > "$HUB_SNIPPET" <<EOF
# Installed by tljh-install-gaussian. Gaussian 16 environment for every
# user's server (notebooks and JupyterLab terminals). Mirrors
# $G16ROOT/g16/bsd/g16.profile; see scripts/install_gaussian.sh for why
# PATH is appended to and PYTHONPATH etc. are not set.
import os

_g16 = "$G16ROOT/g16"
c.Spawner.environment.update({
    "g16root": "$G16ROOT",
    "GAUSS_EXEDIR": _g16 + "/bsd:" + _g16,
    "GAUSS_LEXEDIR": _g16 + "/linda-exe",
    "GAUSS_ARCHDIR": _g16 + "/arch",
    "GAUSS_BSDDIR": _g16 + "/bsd",
    "G16BASIS": _g16 + "/basis",
    "GAUSS_SCRDIR": "$SCRATCH",
    "GAUSS_MDEF": "$MEM_DEFAULT",
    "GAUSS_PDEF": "$NPROC_DEFAULT",
    "PGI_TERM": "trace,abort",
    "_DSM_BARRIER": "SHM",
    # The hub's own PATH is what users' servers inherit; append Gaussian.
    "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin")
            + ":" + _g16 + "/bsd:" + _g16,
})
EOF
    chmod 0644 "$HUB_SNIPPET"
else
    echo "  (would write $HUB_SNIPPET)"
fi

info "Login-shell environment for SSH ($PROFILE_SNIPPET)"
if [[ $DRY_RUN -eq 0 ]]; then
    cat > "$PROFILE_SNIPPET" <<EOF
# Installed by tljh-install-gaussian. Gaussian 16 for SSH logins.
# Skipped in shells that already have it (JupyterLab terminals get it from
# the hub), in non-bash shells (g16.profile uses bash ulimit syntax), and
# for accounts that can't run Gaussian (not in $GROUP).
if [ -n "\${BASH_VERSION:-}" ] && [ -z "\${GAUSS_EXEDIR:-}" ] && [ -x "$G16ROOT/g16/g16" ]; then
    export g16root="$G16ROOT"
    export GAUSS_SCRDIR="$SCRATCH"
    export GAUSS_MDEF="$MEM_DEFAULT"
    export GAUSS_PDEF="$NPROC_DEFAULT"
    . "\$g16root/g16/bsd/g16.profile"
fi
EOF
    chmod 0644 "$PROFILE_SNIPPET"
else
    echo "  (would write $PROFILE_SNIPPET)"
fi

# --- 6. Test job -------------------------------------------------------------------------
# Run Gaussian test 0 (water, RHF/STO-3G; a few seconds) as `nobody` with
# jupyterhub-users as its group: an ordinary group member with no special
# rights, which checks the permissions as well as the program.

if [[ $DRY_RUN -eq 0 ]]; then
    info "Test job 0 as an ordinary member of $GROUP"
    T=$(mktemp -d /tmp/g16test.XXXXXX)
    chown nobody:"$GROUP" "$T"; chmod 0770 "$T"
    if runuser -u nobody -g "$GROUP" -- env -i HOME="$T" \
            g16root="$G16ROOT" GAUSS_SCRDIR="$SCRATCH" \
            PATH="/usr/bin:/bin" bash -c \
            'cd "$HOME" && . "$g16root/g16/bsd/g16.profile" &&
             timeout 600 g16 < "$g16root/g16/tests/com/test0000.com" > test0000.log 2>&1'
    then :; fi
    if grep -q "Normal termination" "$T/test0000.log" 2>/dev/null; then
        got=$(grep -m1 'SCF Done' "$T/test0000.log" | awk '{print $5}')
        ref=$(grep -m1 'SCF Done' "$G16ROOT/g16/tests/amd64/test0000.log" 2>/dev/null | awk '{print $5}' || true)
        info "Test passed: E(RHF) = $got"
        [[ -z "$ref" ]] || echo "    (reference value in Gaussian's test output: $ref)"
        rm -rf -- "${T:?}"
    else
        echo "error: test job failed; the last lines of its output ($T/test0000.log):" >&2
        tail -20 "$T/test0000.log" >&2 || true
        exit 1
    fi
fi

# --- Apply ------------------------------------------------------------------------------

if [[ $RELOAD -eq 1 ]]; then
    info "Reloading the hub so new user servers get Gaussian's environment"
    run tljh-config reload hub
fi

cat <<EOF

==> Gaussian 16 is installed in $G16ROOT/g16.
    Users get it the next time their server starts (File > Hub Control
    Panel > Stop My Server, then start it). Then, in a terminal:
        g16 < input.com > output.log
    or from a notebook cell:
        !g16 < input.com > output.log
    Jobs without %mem / %nproc use $MEM_DEFAULT and $NPROC_DEFAULT processors
    (on the hub, resource_groups.py replaces these with each server's own
    CPU and memory limits, if it is installed).
EOF
