#!/usr/bin/env bash
# Re-run under bash if started with `sh script` (dash on Ubuntu ignores the
# shebang line and can't run bash-only syntax such as {a,b} or [[ ]]).
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
#
# tljh_server_setup.sh - One-time setup of The Littlest JupyterHub (TLJH) for
# the PChem lab on a fresh Ubuntu/Debian server.
#
# Run it from your own admin account (one that can use sudo), not as root:
#   bash scripts/tljh_server_setup.sh
#
# It asks all of its questions first, then runs unattended. Expect 30-60
# minutes; most of that is TeX Live (texlive-full) and the conda environment.
#
# Before running:
#   * Storage: create the ZFS pool (tank) and move /home onto it by hand
#     first (docs/server_setup.md, "Storage"). Step 1 then creates or
#     updates the /srv and /scratch datasets itself. /opt (TLJH and all
#     conda environments) stays on the system SSD.
#   * Gaussian 16 (optional): copy the Gaussian binary folder or archive
#     (currently the B.01 AVX2 build, AVX2.zip) to the server first; the
#     script asks for its path.
#   * GROMACS (optional): the NVIDIA driver must already be installed and
#     working (nvidia-smi); the CUDA toolkit is installed for you.
#   * Network: the server needs outbound HTTPS to tljh.jupyter.org,
#     github.com, pypi.org, conda.anaconda.org (conda-forge) and
#     cdn.playwright.dev (the headless Chromium for WebPDF export); for
#     GROMACS also ftp.gromacs.org, www.fftw.org and
#     developer.download.nvidia.com.
#
# What it does, in order:
#   1. Creates or updates the ZFS datasets for /srv and /scratch (quota,
#      no snapshots, automatic cleanup of old scratch files) and sets the
#      default per-user quota on /home.
#   2. Installs system packages (curl, git, python3, the full TeX Live).
#   3. Installs TLJH with your chosen admin account(s), with sign-up and
#      admin approval as the login method from the hub's first start.
#   4. Installs the admin commands tljh-install-kernel, tljh-make-dropbox,
#      tljh-install-gaussian and tljh-install-gromacs into /usr/local/sbin
#      (GROMACS build settings into /usr/local/etc/tljh), and lets
#      instructors run tljh-make-dropbox.
#   5. Creates /etc/skel-tljh and the /srv/shared folders.
#   6. Patches TLJH so new users' home folders are built from /etc/skel-tljh.
#   7. Sets per-user limits and idle shutdown, limits cron/at to admins, and
#      installs the hub config files in config/jupyterhub_config.d
#      (per-group CPU/memory/GPU, WebPDF browser path).
#   8. Adds JupyterLab extensions and settings to the TLJH user environment.
#   9. Installs notebook templates (each folder in templates/).
#  10. Builds each course's conda environment and registers it as a kernel.
#  11. Optionally installs Gaussian 16 for every hub user (tljh-install-gaussian).
#  12. Optionally builds GROMACS with GPU support (tljh-install-gromacs).
#  13. Reloads the hub so every change takes effect.
#
# To update just the admin commands or their settings after editing them,
# repeat step 4's `install` lines by hand, or re-run this script.
#
# After it finishes, read the notes printed at the end ("Next steps" etc.).
# They are also saved in /var/log/tljh_server_setup/ (latest.txt is the newest).
#
# The script is safe to re-run: every step checks what is already done.

set -euo pipefail
trap 'echo "error: setup stopped at line $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR=$(readlink -f "$(dirname -- "$0")")
CENV_DIR=$(readlink -f "$SCRIPT_DIR/../environments")
TEMPLATES_SRC=$(readlink -f "$SCRIPT_DIR/../templates")
CONFIG_SRC=$(readlink -f "$SCRIPT_DIR/../config")
HUB_CONFIG_SRC="$CONFIG_SRC/jupyterhub_config.d"   # -> /opt/tljh/config/jupyterhub_config.d
HUB_CONFIG_DIR=/opt/tljh/config/jupyterhub_config.d
PLAYWRIGHT_DIR=/opt/tljh/playwright   # shared headless Chromium for WebPDF
TLJH_USER=/opt/tljh/user          # env that serves JupyterLab to every user
SKEL_DIR=/etc/skel-tljh           # template for new users' home folders
SHARED_DIR=/srv/shared            # course data and assignment drop boxes
TOOLS_DIR=/usr/local/sbin         # where the admin commands are installed
TOOLS_ETC=/usr/local/etc/tljh     # settings files for the admin commands
INSTRUCTORS_GROUP=jupyterhub-instructors

# Storage (step 1). The pool is created by hand beforehand; see
# docs/server_setup.md. Changing a value and re-running updates the server.
ZPOOL=tank
SRV_DATASET=$ZPOOL/srv            # mounted at /srv
SCRATCH_DATASET=$ZPOOL/scratch    # mounted at /scratch
HOME_DATASET=$ZPOOL/home          # mounted at /home (moved there by hand)
HOME_DEFAULT_QUOTA=10G            # per-user home quota for everyone without
                                  # their own (zfs set userquota@<user>=...)
SCRATCH_QUOTA=3T                  # cap on all of /scratch, so it can't fill /home's pool
SCRATCH_USERS=/scratch/users      # per-user scratch folders
SCRATCH_MAX_AGE=14d               # delete scratch files untouched this long
SCRATCH_TMPFILES=/etc/tmpfiles.d/tljh-scratch.conf

# Course kernels installed in step 10, one per line:
#   "<file in environments/>|<label shown in JupyterLab's kernel menu>"
# The kernel's internal name comes from the file's `name:` key (pchem2,
# compchem, ...); notebooks find their kernel by that name, so keep it stable.
# To add a course later, add a line here and re-run, or just run
#   sudo -E tljh-install-kernel -d "<label>" environments/<file>
COURSE_KERNELS=(
    "pchem2_env.yaml|Python (PChem Lab)"
    "compchem_env.yaml|Python (CompChem)"
)

# Plain Ubuntu PATH. Every TLJH program below is called by its full path, so
# nothing from the caller's shell (e.g. an active conda env) can interfere.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

step() { printf '\n==== %s ====\n' "$*"; }
die()  { echo "error: $*" >&2; exit 1; }

# --- Questions (asked up front so the rest can run unattended) ---------------

step "Setup questions"

read -r -p "TLJH admin username(s), separated by spaces: " -a ADMIN_USERS
[[ ${#ADMIN_USERS[@]} -gt 0 ]] || die "at least one admin username is required"
for u in "${ADMIN_USERS[@]}"; do
    [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] \
        || die "'$u' is not a valid Linux username (lowercase letters, digits, _ or -)"
done

for entry in "${COURSE_KERNELS[@]}"; do
    [[ -f "$CENV_DIR/${entry%%|*}" ]] || die "missing course environment file: $CENV_DIR/${entry%%|*}"
done

BASE_REQS="$CENV_DIR/base_requirements.txt"
[[ -f "$BASE_REQS" ]] || die "missing $BASE_REQS"
[[ -f "$CONFIG_SRC/jupyter_config.py" ]] || die "missing $CONFIG_SRC/jupyter_config.py"

# Gaussian 16 (step 11): optional; blank skips it. Re-run later on its own
# with: sudo tljh-install-gaussian <path>
read -r -e -p "Path to the Gaussian 16 files on this server (folder or archive; blank to skip): " G16_SRC
if [[ -n "$G16_SRC" ]]; then
    G16_SRC=${G16_SRC/#\~/$HOME}
    G16_SRC=$(realpath -e -- "$G16_SRC" 2>/dev/null) || die "Gaussian files not found: $G16_SRC"
    if [[ -d "$G16_SRC" ]]; then
        [[ -f "$G16_SRC/g16" || -f "$G16_SRC/g16/g16" ]] \
            || die "$G16_SRC doesn't look like a Gaussian 16 folder (no g16 program inside)"
    fi
fi
[[ -f "$SCRIPT_DIR/install_gaussian.sh" ]] || die "missing $SCRIPT_DIR/install_gaussian.sh"

# Hub config files (step 7). A Python error in one of them would stop the
# hub from starting, so check their syntax now.
HUB_CONFIG_FILES=("$HUB_CONFIG_SRC"/*.py)
[[ -f "${HUB_CONFIG_FILES[0]}" ]] || die "no hub config files found in $HUB_CONFIG_SRC"
for f in "${HUB_CONFIG_FILES[@]}"; do
    python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$f" \
        || die "syntax error in $f"
done

# GROMACS (step 12): optional. Version and build options are in
# config/gromacs_build.conf and config/gromacs_cache.cmake.
for f in "$SCRIPT_DIR/install_gromacs.sh" "$CONFIG_SRC/gromacs_build.conf" "$CONFIG_SRC/gromacs_cache.cmake"; do
    [[ -f "$f" ]] || die "missing $f"
done
GMX_VERSION=$(sed -n 's/^GMX_VERSION="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$CONFIG_SRC/gromacs_build.conf")
read -r -p "Build GROMACS $GMX_VERSION with GPU support (adds 20-60 min)? [y/N] " ans
BUILD_GROMACS=0
if [[ "$ans" =~ ^[Yy] ]]; then
    BUILD_GROMACS=1
    command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1 \
        || die "GROMACS needs a working NVIDIA driver first (nvidia-smi failed); install it, reboot, and re-run"
fi

# Template folders to install (step 9): every folder directly in templates/.
TEMPLATE_FOLDERS=()
if [[ -d "$TEMPLATES_SRC" ]]; then
    for d in "$TEMPLATES_SRC"/*/; do
        [[ -d "$d" ]] && TEMPLATE_FOLDERS+=("$(basename -- "$d")")
    done
fi

cat <<EOF

About to install TLJH with:
  admin(s)       : ${ADMIN_USERS[*]}
  course kernels : $(printf '%s; ' "${COURSE_KERNELS[@]}" | sed 's/|/ -> /g; s/; $//')
  base extras    : $BASE_REQS
  templates      : ${TEMPLATE_FOLDERS[*]:-(none found in $TEMPLATES_SRC)}
  storage        : $SRV_DATASET -> /srv, $SCRATCH_DATASET -> /scratch (quota $SCRATCH_QUOTA, cleanup after $SCRATCH_MAX_AGE)
  Gaussian 16    : ${G16_SRC:-(skipped)}
  GROMACS        : $([[ $BUILD_GROMACS -eq 1 ]] && echo "$GMX_VERSION (CUDA)" || echo "(skipped)")
EOF
read -r -p "Continue? [y/N] " ok
[[ "$ok" =~ ^[Yy] ]] || die "cancelled"

# Ask for the sudo password once, then keep sudo alive until the script ends.
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done >/dev/null 2>&1 &
KEEPALIVE_PID=$!
trap 'kill "$KEEPALIVE_PID" 2>/dev/null || true' EXIT

# --- 1. Storage: ZFS datasets for /srv and /scratch ----------------------------
# The ZFS pool ($ZPOOL, a mirror of the two HDDs) and /home on it are set up
# by hand beforehand (docs/server_setup.md, "Storage"). This step creates
# the /srv and /scratch datasets, or brings existing ones in line with the
# settings below, so it is safe to re-run. It never deletes or moves files:
# if /srv or /scratch already holds files that are not on the right
# dataset, it stops and says what to do.
#
#   $SRV_DATASET -> /srv      course data and drop boxes. POSIX ACLs on
#                             (tljh-make-dropbox needs them), atime off.
#                             Backed up and snapshotted like /home.
#   $SCRATCH_DATASET -> /scratch
#                             temporary job files. Never snapshotted or
#                             backed up (com.sun:auto-snapshot=false; leave
#                             it out of zfs send/syncoid too). A quota stops
#                             it filling the pool that /home lives on.
#                             atime on (relatime: updated at most daily),
#                             because the cleanup below keeps a file only
#                             while one of its access/change/modify/creation
#                             times is recent; with atime off, a file that is
#                             only read (a job's input) would be deleted.
#   $SCRATCH_DATASET/g16 -> /scratch/g16
#                             Gaussian scratch. tljh-install-gaussian sets
#                             its permissions (3770) and 7-day cleanup.
#   /scratch/users            one folder per user (anyone can create one;
#                             the sticky bit, as on /tmp, stops users
#                             deleting each other's). Anything inside a
#                             user's folder untouched for $SCRATCH_MAX_AGE is
#                             deleted by the daily systemd-tmpfiles-clean
#                             timer; the per-user folders themselves stay.
#
# Compression: both datasets inherit lz4 from the pool; it is set on the
# dataset only if compression is off.

step "1/13 Storage: ZFS datasets for /srv and /scratch"

command -v zfs >/dev/null || die "ZFS tools not installed (sudo apt install zfsutils-linux); set up the pool first, see docs/server_setup.md"
sudo zpool list -H -o name "$ZPOOL" >/dev/null 2>&1 \
    || die "ZFS pool '$ZPOOL' not found; create it first (docs/server_setup.md, Storage), or change ZPOOL at the top of this script"
pool_health=$(sudo zpool list -H -o health "$ZPOOL")
[[ "$pool_health" == ONLINE ]] || echo "WARNING: pool $ZPOOL is $pool_health, not ONLINE; check 'zpool status $ZPOOL'"
[[ "$(findmnt -n -o FSTYPE --target /home)" == zfs ]] \
    || echo "WARNING: /home is not on ZFS; see docs/server_setup.md (Storage) to move it"

# True if a dataset can be mounted at $1: the path doesn't exist, or is an
# empty folder that nothing else is mounted on.
mount_target_free() {
    [[ -e "$1" ]] || return 0
    [[ -d "$1" && ! -L "$1" ]] || return 1
    findmnt -n --mountpoint "$1" >/dev/null && return 1
    [[ -z "$(sudo ls -A -- "$1")" ]]
}

# ensure_dataset <dataset> <mountpoint>: create the dataset, or move an
# existing one to the right mountpoint, then make sure it is mounted.
ensure_dataset() {
    local ds=$1 mp=$2 cur
    if sudo zfs list -H -o name "$ds" >/dev/null 2>&1; then
        cur=$(sudo zfs get -H -o value mountpoint "$ds")
        if [[ "$cur" != "$mp" ]]; then
            mount_target_free "$mp" || die "$ds is mounted at $cur, but $mp already has files or another filesystem mounted on it (see: findmnt $mp; ls -A $mp). Move those files onto $ds by hand, then re-run."
            echo "Moving $ds from $cur to $mp"
            sudo zfs set mountpoint="$mp" "$ds"
        else
            echo "Found $ds at $mp"
        fi
    else
        mount_target_free "$mp" || die "$mp already has files or another filesystem mounted on it (see: findmnt $mp; ls -A $mp). Copy them into a new $ds dataset by hand (as for /home in docs/server_setup.md), then re-run."
        echo "Creating $ds at $mp"
        sudo zfs create -o mountpoint="$mp" "$ds"
    fi
    [[ "$(sudo zfs get -H -o value mounted "$ds")" == yes ]] \
        || sudo zfs mount "$ds" \
        || die "could not mount $ds at $mp"
}

ensure_lz4() {
    if [[ "$(sudo zfs get -H -o value compression "$1")" == off ]]; then
        sudo zfs set compression=lz4 "$1"
    fi
}

# /srv
ensure_dataset "$SRV_DATASET" /srv
sudo zfs set acltype=posix xattr=sa atime=off setuid=off devices=off "$SRV_DATASET"
ensure_lz4 "$SRV_DATASET"
sudo chown root:root /srv
sudo chmod 0755 /srv

# /scratch
ensure_dataset "$SCRATCH_DATASET" /scratch
sudo zfs set atime=on relatime=on setuid=off devices=off \
    quota="$SCRATCH_QUOTA" com.sun:auto-snapshot=false "$SCRATCH_DATASET"
ensure_lz4 "$SCRATCH_DATASET"
sudo chown root:root /scratch
sudo chmod 0755 /scratch

# /scratch/g16 (permissions and cleanup are set by tljh-install-gaussian)
ensure_dataset "$SCRATCH_DATASET/g16" /scratch/g16

# /scratch/users and its cleanup rule.
sudo tee "$SCRATCH_TMPFILES" >/dev/null <<RULE
# Installed by tljh_server_setup.sh: shared scratch area. Anything inside a
# user's folder (/scratch/users/<name>/...) untouched for $SCRATCH_MAX_AGE is deleted by
# the daily systemd-tmpfiles-clean timer; '~' keeps the per-user folders.
d $SCRATCH_USERS 1777 root root ~$SCRATCH_MAX_AGE
RULE
sudo chmod 0644 "$SCRATCH_TMPFILES"
sudo systemd-tmpfiles --create "$SCRATCH_TMPFILES"
sudo chown root:root "$SCRATCH_USERS"
sudo chmod 01777 "$SCRATCH_USERS"
sudo tee "$SCRATCH_USERS/README.txt" >/dev/null <<README
Scratch space for running jobs. Make your own folder:  mkdir -p $SCRATCH_USERS/\$USER
NOT backed up. Files untouched for $SCRATCH_MAX_AGE are deleted automatically.
README
sudo chmod 0644 "$SCRATCH_USERS/README.txt"

sudo zfs list -o name,mountpoint,used,avail,quota,compression,atime \
    "$SRV_DATASET" "$SCRATCH_DATASET" "$SCRATCH_DATASET/g16"

# Home folder quotas: defaultuserquota (OpenZFS 2.4+) applies to every user
# who has no quota of their own, including users created later, so new hub
# accounts need no extra step. Give someone more (or less) with
#   sudo zfs set userquota@<user>=<size> $HOME_DATASET
# and check usage with: zfs userspace $HOME_DATASET
if sudo zfs list -H -o name "$HOME_DATASET" >/dev/null 2>&1; then
    if sudo zfs get -H -o value defaultuserquota "$HOME_DATASET" >/dev/null 2>&1; then
        sudo zfs set defaultuserquota="$HOME_DEFAULT_QUOTA" "$HOME_DATASET"
        echo "Default home quota on $HOME_DATASET: $(sudo zfs get -H -o value defaultuserquota "$HOME_DATASET")"
    else
        echo "WARNING: this ZFS ($(zfs version 2>/dev/null | head -1)) has no defaultuserquota (needs OpenZFS 2.4+);"
        echo "         set home quotas per user: sudo zfs set userquota@<user>=$HOME_DEFAULT_QUOTA $HOME_DATASET"
    fi
else
    echo "WARNING: $HOME_DATASET not found, so no home quota was set; see docs/server_setup.md (Storage)"
fi

# --- 2. System packages ------------------------------------------------------
# texlive-full is every TeX Live collection Ubuntu packages: all LaTeX
# classes and packages (incl. achemso, chemmacros, mhchem used by
# templates/pchem/latex_report.tex), all fonts and language packs, biber,
# latexmk, and the documentation. jupyterlab-latex uses it to build PDFs.
# It is several GB and the slowest part of this script.
# acl provides setfacl/getfacl, used by tljh-make-dropbox.
# DEBIAN_FRONTEND=noninteractive keeps apt from stopping to ask questions.

step "2/13 System packages"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl git python3 python3-dev acl texlive-full

# --- 3. TLJH -----------------------------------------------------------------
# -E passes proxy settings through (as TLJH's docs recommend); -H keeps
# root's caches out of your home folder. Re-running upgrades TLJH in place.
#
# Login method, set BEFORE the hub first starts. TLJH's default
# (FirstUseAuthenticator) lets whoever logs in first under a username set
# its password, admin names included, and the hub starts as soon as TLJH is
# installed. So config.yaml is written first with NativeAuthenticator
# (people sign up, an admin approves them), which TLJH's installer keeps:
#   allow_all              REQUIRED since JupyterHub 5: without it (or an
#                          allowed_users list) JupyterHub turns away every
#                          non-admin, even approved ones. It does not skip
#                          approval; NativeAuthenticator checks that first.
#   check_common_password  refuse sign-ups with common passwords ("qwerty",
#                          "123456", ...)
# After installing, the same settings are applied again and the hub
# reloaded, which also covers a config.yaml left by an earlier install.
# Admin usernames are approved automatically when they sign up, so sign up
# as each admin right after setup (see the notes at the end).

step "3/13 Installing The Littlest JupyterHub"
TLJH_CONFIG=/opt/tljh/config/config.yaml
if ! sudo test -e "$TLJH_CONFIG"; then
    sudo install -d -m 0755 -o root -g root /opt/tljh
    sudo install -d -m 0700 -o root -g root /opt/tljh/config
    sudo tee "$TLJH_CONFIG" >/dev/null <<'YAML'
# Written by tljh_server_setup.sh before TLJH's first start; managed with
# tljh-config from here on.
auth:
  type: nativeauthenticator.NativeAuthenticator
  NativeAuthenticator:
    allow_all: true
    check_common_password: true
YAML
    sudo chmod 0600 "$TLJH_CONFIG"
fi
curl -fsSL https://tljh.jupyter.org/bootstrap.py \
    | sudo -EH python3 - --admin "${ADMIN_USERS[@]}"
sudo tljh-config set auth.type nativeauthenticator.NativeAuthenticator
sudo tljh-config set auth.NativeAuthenticator.allow_all true
sudo tljh-config set auth.NativeAuthenticator.check_common_password true
sudo tljh-config reload hub
echo "Login method: $(sudo tljh-config show | sed -n 's/^ *type: *//p' | head -1)"

# --- 4. Admin commands -------------------------------------------------------
# Installed copies live in /usr/local/sbin (the standard place for local
# admin tools; it is on sudo's search path), owned by root and not writable
# by anyone else. That matters: instructors may run tljh-make-dropbox as
# root, so they must not be able to edit it. Names start with `tljh-` to
# match TLJH's own tljh-config command and group them for tab completion.
#
#   tljh-install-kernel  admins only:  sudo -E tljh-install-kernel <file>
#                        (it installs software as root, which is equivalent
#                        to full root access, so instructors don't get it)
#   tljh-make-dropbox    admins, and instructors for their own folders:
#                        sudo tljh-make-dropbox <folder> <instructor>
#   tljh-install-gaussian  admins only: sudo tljh-install-gaussian <files>
#   tljh-install-gromacs   admins only: sudo -E tljh-install-gromacs
#                          (settings: /usr/local/etc/tljh/gromacs_build.conf)
#
# Hub accounts have no Linux password, so the instructors' sudo rule is
# NOPASSWD and limited to that one command. The script itself refuses to
# act on another instructor's folder when run by a non-admin.

step "4/13 Admin commands"
sudo groupadd -f "$INSTRUCTORS_GROUP"
sudo install -m 0755 -o root -g root "$SCRIPT_DIR/install_kernel.sh" "$TOOLS_DIR/tljh-install-kernel"
sudo install -m 0755 -o root -g root "$SCRIPT_DIR/make_dropbox.sh"   "$TOOLS_DIR/tljh-make-dropbox"
sudo install -m 0755 -o root -g root "$SCRIPT_DIR/install_gaussian.sh" "$TOOLS_DIR/tljh-install-gaussian"
sudo install -m 0755 -o root -g root "$SCRIPT_DIR/install_gromacs.sh"  "$TOOLS_DIR/tljh-install-gromacs"
sudo install -d -m 0755 -o root -g root "$TOOLS_ETC"
sudo install -m 0644 -o root -g root "$CONFIG_SRC/gromacs_build.conf" "$CONFIG_SRC/gromacs_cache.cmake" "$TOOLS_ETC/"

sudoers_tmp=$(mktemp)
cat > "$sudoers_tmp" <<EOF
# Installed by tljh_server_setup.sh. Lets instructors create and repair
# their own submission drop boxes; the script enforces "own folders only".
%$INSTRUCTORS_GROUP ALL=(root) NOPASSWD: $TOOLS_DIR/tljh-make-dropbox
EOF
# visudo -c checks the syntax first; a broken sudoers file can lock out sudo.
sudo visudo -cqf "$sudoers_tmp" || die "generated sudoers rule failed validation"
sudo install -m 0440 -o root -g root "$sudoers_tmp" /etc/sudoers.d/jupyterhub-instructors
rm -f "$sudoers_tmp"
echo "Installed tljh-install-kernel, tljh-make-dropbox, tljh-install-gaussian and tljh-install-gromacs in $TOOLS_DIR"

# --- 5. Skeleton home folder and shared folders --------------------------------
# /srv/shared/lab_data     instructors write, everyone reads (course data:
#                          fret/, nmr/, ...). Same name as on the old server,
#                          so notebook paths like ~/shared/lab_data/... work.
# /srv/shared/submissions  everyone can browse it, only root writes to it.
#                          It holds one drop box per instructor/course, each
#                          created with tljh-make-dropbox.
# Every new user gets a `shared` link to /srv/shared in their home folder.
# /srv itself is the ZFS dataset made in step 1.

step "5/13 Skeleton home folder and /srv/shared"
[[ -d "$SKEL_DIR" ]] || sudo cp -a /etc/skel "$SKEL_DIR"
sudo install -d -m 0755 -o root -g root "$SHARED_DIR"
sudo install -d -m 2775 -o root -g "$INSTRUCTORS_GROUP" "$SHARED_DIR/lab_data"
sudo install -d -m 0755 -o root -g root "$SHARED_DIR/submissions"
sudo ln -sfn "$SHARED_DIR" "$SKEL_DIR/shared"

# --- 6. Make TLJH build new home folders from /etc/skel-tljh --------------------
# TLJH creates each Linux account the first time that person logs in, using
# `useradd --create-home`. This adds `--skel /etc/skel-tljh` to that call.
# NOTE: upgrading TLJH replaces this file. Re-run this script after upgrades.

step "6/13 Patching TLJH user creation"
USER_PY=$(sudo find /opt/tljh/hub -path '*/site-packages/tljh/user.py' -print -quit)
[[ -n "$USER_PY" ]] || die "could not find tljh/user.py under /opt/tljh/hub"
if sudo grep -qF "\"--skel\", \"$SKEL_DIR\"" "$USER_PY"; then
    echo "Already patched: $USER_PY"
else
    sudo sed -i "s|\"--create-home\"|\"--create-home\", \"--skel\", \"$SKEL_DIR\"|" "$USER_PY"
    sudo grep -qF "\"--skel\", \"$SKEL_DIR\"" "$USER_PY" \
        || die "patch failed: TLJH's useradd call has changed; see $USER_PY"
    echo "Patched: $USER_PY"
fi

# --- 7. Resource limits, idle shutdown, scheduled jobs -------------------------
# (The login method is set in step 3, before the hub first starts.)
#
# Per-user limits (TLJH's default is no limits). Each user's server may use
# at most 4 CPUs and 8 GB of memory. Going over the memory limit kills that
# user's kernel; the CPU limit only slows them down. These are ceilings, not
# reservations, so they don't need to add up to the machine's total.
#
# Idle shutdown: a user server with no activity for 1 hour is stopped
# (TLJH's default is 10 minutes). Running kernels and unsaved variables are
# lost; saved files are not.

step "7/13 Resource limits, idle shutdown, scheduled jobs and hub config files"
sudo tljh-config set limits.cpu 4
sudo tljh-config set limits.memory 8G
sudo tljh-config set services.cull.timeout 3600

# Scheduled jobs. cron and at run jobs outside users' Jupyter servers, so
# without this a user could escape their CPU, memory and GPU limits with a
# crontab. On Ubuntu every user may use them unless an allow file exists; an
# allow file limits them to the accounts listed. Keeps any accounts already
# listed; adds root and the account running this script. Add others by hand
# (one username per line). Files are created even if cron/at aren't
# installed yet, so they apply if either is installed later.
for allow in /etc/cron.allow /etc/at.allow; do
    sudo touch "$allow"
    for acct in root "$(id -un)"; do
        sudo grep -qx -- "$acct" "$allow" || echo "$acct" | sudo tee -a "$allow" >/dev/null
    done
    sudo chown root:root "$allow"
    sudo chmod 0644 "$allow"
    echo "$allow: $(sudo paste -sd' ' "$allow")"
done

# Hub config files from the repo's config/jupyterhub_config.d. TLJH loads
# every *.py in $HUB_CONFIG_DIR, in alphabetical order, after its own
# settings. Re-running replaces these files; others in that folder (e.g.
# gaussian.py and gromacs.py, written by their installers) are left alone.
#   resource_groups.py  hub groups "instructors" (8 CPUs / 16 GB),
#                       "research" (16 / 32 GB) and "gpu" (GPU access; no
#                       one else's server can see the GPU). Members are
#                       managed on the Admin page; see the notes at the end.
#   playwright.py       where users' servers find the WebPDF browser (step 8)
sudo install -d -m 0755 -o root -g root "$HUB_CONFIG_DIR"
sudo install -m 0644 -o root -g root "${HUB_CONFIG_FILES[@]}" "$HUB_CONFIG_DIR/"
echo "Installed $(printf '%s ' "${HUB_CONFIG_FILES[@]##*/}")into $HUB_CONFIG_DIR"

# --- 8. JupyterLab extensions in the TLJH user environment --------------------------
# Installed with pip, NOT conda: TLJH installs JupyterLab, notebook and
# ipywidgets into /opt/tljh/user with pip, and adding conda copies of the
# same packages on top leaves duplicate, conflicting installs.

step "8/13 JupyterLab extensions and settings (base environment)"
sudo -EH "$TLJH_USER/bin/python" -m pip install --upgrade pip
sudo -EH "$TLJH_USER/bin/python" -m pip install -r "$BASE_REQS"

# Settings for every user's Jupyter server, merged into
# /opt/tljh/user/etc/jupyter/jupyter_server_config.json (any other settings
# already in that file are kept):
#   ContentsManager.allow_hidden          JupyterLab may open dotfiles and
#                                         dot-folders (users still choose
#                                         "Show Hidden Files" to list them)
#   ResourceUseDisplay.track_cpu_percent  status bar shows CPU % as well as
#                                         memory (jupyter-resource-usage)
#   JupyterLabTemplates.include_default   false: hide the extension's sample
#   JupyterLabTemplates.allowed_extensions  offer .tex templates as well as
#                                         notebooks (they open as .tex files)
# Settings in /opt/tljh/config/config.yaml do NOT reach users' servers; TLJH
# only reads its own keys there (auth, users, limits, ...). And
# jupyter_server_config.d/*.json is only read for enabling extensions.
# Users get changes the next time their server starts.
server_cfg="$TLJH_USER/etc/jupyter/jupyter_server_config.json"
sudo install -d -m 0755 "$(dirname "$server_cfg")"
sudo "$TLJH_USER/bin/python" - "$server_cfg" <<'PY'
import json, os, sys
path = sys.argv[1]
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        cfg = json.load(f)
settings = {
    "ContentsManager": {"allow_hidden": True},
    "ResourceUseDisplay": {"track_cpu_percent": True},
    "JupyterLabTemplates": {
        "include_default": False,
        "allowed_extensions": ["*.ipynb", "*.tex"],
    },
}
for section, values in settings.items():
    cfg.setdefault(section, {}).update(values)
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("Updated", path)
PY
sudo chmod 0644 "$server_cfg"

# Export settings (formats in "Save and Export Notebook As", tag removal),
# from the repo's config/jupyter_config.py. Re-running replaces the file.
sudo install -m 0644 -o root -g root "$CONFIG_SRC/jupyter_config.py" \
    "$TLJH_USER/etc/jupyter/jupyter_config.py"

# WebPDF export drives a headless Chromium through Playwright. Install one
# shared copy (plus the system libraries it needs) in $PLAYWRIGHT_DIR.
# Users' servers find it through PLAYWRIGHT_BROWSERS_PATH, set by
# config/jupyterhub_config.d/playwright.py (installed in step 7).
# Playwright runs Chromium without its sandbox by default, so Ubuntu's
# restriction on unprivileged user namespaces doesn't get in the way; each
# export runs as the student who asked for it.
sudo -EH env PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_DIR" \
    "$TLJH_USER/bin/python" -m playwright install --with-deps chromium
sudo chmod -R a+rX "$PLAYWRIGHT_DIR"

# --- 9. Notebook templates --------------------------------------------------------
# Each FOLDER in the repo's templates/ folder is copied to
#   /opt/tljh/user/share/jupyter/notebook_templates/<folder>/
# which the jupyterlab_templates extension searches automatically. Users pick
# them from the Template launcher in JupyterLab, listed as <folder>/<file>.
# Loose files directly in templates/ are skipped; the extension ignores
# top-level files anyway.
#
# Re-running replaces each folder with the repo's current copy, so edits and
# deletions inside a folder carry over. A whole folder deleted from the repo
# stays on the server until you remove it from notebook_templates by hand.
#
# The template extension's settings (hide its sample template, allow .tex
# templates) are written in step 8; changes to those take effect when a
# user's server next starts. The template files themselves are re-read each
# time someone opens the Template dialog, so new or edited templates show up
# right away. Users can also keep personal templates in
# ~/.local/share/jupyter/notebook_templates/<folder>/.

step "9/13 Notebook templates"
TEMPLATES_DEST="$TLJH_USER/share/jupyter/notebook_templates"
sudo install -d -m 0755 -o root -g root "$TEMPLATES_DEST"
for f in "$TEMPLATES_SRC"/*; do
    [[ -e "$f" && ! -d "$f" ]] && echo "Skipping $(basename -- "$f"): only folders in templates/ are installed"
done
for name in "${TEMPLATE_FOLDERS[@]}"; do
    dest="$TEMPLATES_DEST/$name"
    sudo rm -rf -- "${dest:?}"
    sudo cp -R -- "$TEMPLATES_SRC/$name" "$dest"
    # Drop Mac/Jupyter clutter, then make it root-owned and readable by all.
    sudo find "$dest" \( -name .DS_Store -o -name '._*' \) -type f -delete
    sudo find "$dest" -name .ipynb_checkpoints -type d -prune -exec rm -rf {} +
    sudo chown -R root:root "$dest"
    sudo chmod -R u=rwX,go=rX "$dest"
    echo "Installed template folder '$name':"
    find "$dest" -type f -printf '    %P\n'
done


# --- 10. Course environments and kernels -------------------------------------------
# tljh-install-kernel creates each conda env from COURSE_KERNELS (top of this
# script) and registers it as a kernel for all users. Re-running updates
# existing envs in place.

step "10/13 Course environments and kernels"
for entry in "${COURSE_KERNELS[@]}"; do
    env_file="$CENV_DIR/${entry%%|*}"
    label="${entry#*|}"
    echo "--- $label ($env_file)"
    sudo -E "$TOOLS_DIR/tljh-install-kernel" -d "$label" "$env_file"
done

# --- 11. Gaussian 16 (optional) --------------------------------------------------------
# tljh-install-gaussian installs the binaries in /opt/gaussian/g16 for the
# jupyterhub-users group (every hub account), creates /scratch/g16, sets the
# Gaussian environment for notebooks, JupyterLab terminals and SSH logins,
# and runs Gaussian's test job 0 as an ordinary user. See its --help.
# --no-reload: step 13 reloads the hub.

if [[ -n "$G16_SRC" ]]; then
    step "11/13 Gaussian 16"
    sudo "$TOOLS_DIR/tljh-install-gaussian" --no-reload "$G16_SRC"
else
    step "11/13 Gaussian 16 (skipped)"
fi

# --- 12. GROMACS (optional) --------------------------------------------------------------
# tljh-install-gromacs builds GROMACS from source with CUDA (installing the
# CUDA toolkit if needed), runs its tests, installs it in
# /opt/gromacs/<version> (/opt/gromacs/current), puts `gmx` on every user's
# PATH, and builds gmxapi into the compchem kernel (step 10 must come first).
# --no-reload: step 13 reloads the hub.

if [[ $BUILD_GROMACS -eq 1 ]]; then
    step "12/13 GROMACS $GMX_VERSION"
    sudo -E "$TOOLS_DIR/tljh-install-gromacs" --no-reload
else
    step "12/13 GROMACS (skipped)"
fi

# --- 13. Apply changes -----------------------------------------------------------------

step "13/13 Reloading the hub and proxy"
sudo tljh-config reload proxy
sudo tljh-config reload hub

# --- Notes for the administrator -------------------------------------------------------
# Printed to the terminal and saved in $NOTES_DIR (one file per run, plus
# latest.txt pointing at the newest), so they're still there after the
# terminal is closed. The last line printed says where the file is.

NOTES_DIR=/var/log/tljh_server_setup
NOTES_FILE="$NOTES_DIR/setup-notes-$(date +%Y%m%d-%H%M%S).txt"
HUB_URL="http://$(hostname -f 2>/dev/null || hostname)"
REPO_VERSION=$(git -C "$SCRIPT_DIR/.." describe --always --dirty 2>/dev/null || echo unknown)
G16_INSTALLED=0; sudo test -x /opt/gaussian/g16/g16 && G16_INSTALLED=1
GMX_INSTALLED=0; sudo test -x /opt/gromacs/current/bin/gmx && GMX_INSTALLED=1
CLOCK_SYNCED=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)

admin_notes() {
    cat <<EOT
==== Setup complete ====

Run on $(hostname) at $(date '+%Y-%m-%d %H:%M %Z') by ${USER:-$(id -un)} (repo version $REPO_VERSION).
  admin(s)       : ${ADMIN_USERS[*]}
  course kernels : $(printf '%s; ' "${COURSE_KERNELS[@]}" | sed 's/|/ -> /g; s/; $//')
  Gaussian 16    : $([[ $G16_INSTALLED -eq 1 ]] && echo "installed in /opt/gaussian" || echo "not installed")
  GROMACS        : $([[ $GMX_INSTALLED -eq 1 ]] && echo "installed, /opt/gromacs/current -> $(sudo readlink /opt/gromacs/current)" || echo "not installed")
EOT
    if [[ "$CLOCK_SYNCED" != yes ]]; then
        cat <<EOT

WARNING: the system clock is not synchronized by NTP (NTPSynchronized=$CLOCK_SYNCED).
Submission timestamps and logs will drift. See docs/server_setup.md, "Time sync".
EOT
    fi
    cat <<EOT

Next steps:
  1. Now, before the hub is reachable from outside: open
     $HUB_URL/hub/signup and sign up as each admin (${ADMIN_USERS[*]}).
     Admin names are approved automatically, so whoever signs up first
     under one becomes that admin.
  2. Work through the Testing checklist in docs/server_setup.md (kernels,
     scratch, limits and groups, GPU, exports, drop boxes, Gaussian, GROMACS).
  3. Set up HTTPS and the DMZ proxy (see docs/server_setup.md).
  4. Approve students at /hub/authorize as they sign up.
  5. Home folder quotas are automatic: every user without their own quota
     gets $HOME_DEFAULT_QUOTA on $HOME_DATASET (defaultuserquota), admins included,
     so give yourself more if needed. To change one user's quota:
       sudo zfs set userquota@jupyter-<name>=<size> $HOME_DATASET
       zfs userspace $HOME_DATASET            (usage and quotas)
  6. For each instructor: have them log in once, then run
       sudo usermod -aG $INSTRUCTORS_GROUP jupyter-<name>
       sudo tljh-make-dropbox <name>_<course>_<term> jupyter-<name>
     Group changes take effect when their server next starts
     (File > Hub Control Panel > Stop My Server, then start it again).
  7. Bigger servers and the GPU: on the Admin page ($HUB_URL/hub/admin),
     "Groups", add hub usernames (e.g. dwheeler, not jupyter-dwheeler) to
       instructors  8 CPUs / 16 GB      research  16 CPUs / 32 GB
       gpu          can use the GPU (nobody else's server can see it)
     Everyone else gets 4 CPUs / 8 GB and no GPU. A user in several groups
     gets the largest. Changes apply when their server next starts. Limits
     and groups are set in $HUB_CONFIG_DIR/resource_groups.py
     (repo: config/jupyterhub_config.d); after editing, re-run step 7's
     install line or this script, then: sudo tljh-config reload hub

Storage ($ZPOOL):
$(sudo zfs list -r -o name,mountpoint,used,avail,quota "$ZPOOL" 2>&1 | sed 's/^/  /')
  /scratch is NOT backed up or snapshotted. Files inside /scratch/users/<name>
  untouched for $SCRATCH_MAX_AGE are deleted daily ($SCRATCH_TMPFILES);
  /scratch/g16 keeps 7 days. Total /scratch quota: $SCRATCH_QUOTA.
  Back up $ZPOOL/home and $SRV_DATASET one at a time; "zfs send -R $ZPOOL" would
  include scratch.

Admin commands (run "<command> --help" for details):
  sudo -E tljh-install-kernel <env-file>     add or update a course kernel
  sudo tljh-make-dropbox <folder> <user>     create or repair a drop box
  sudo tljh-install-gaussian <files>         install or replace Gaussian 16
  sudo -E tljh-install-gromacs               build/upgrade GROMACS (settings in
                                             $TOOLS_ETC/gromacs_build.conf)
EOT
    if [[ $G16_INSTALLED -eq 1 ]]; then
        cat <<EOT

Gaussian 16 runs for every hub account, in a terminal or a notebook cell:
  g16 < input.com > output.log
Other Linux accounts (e.g. your own SSH login) need adding once:
  sudo usermod -aG jupyterhub-users <account>
EOT
    fi
    if [[ $GMX_INSTALLED -eq 1 ]]; then
        cat <<EOT

GROMACS: gmx is on every user's PATH (the GPU only for the "gpu" group).
mdrun counts all 64 logical CPUs, so give it the server's limit, e.g.
  gmx mdrun -ntmpi 1 -ntomp \$OMP_NUM_THREADS   (OMP_NUM_THREADS = the CPU limit)
EOT
    fi
    cat <<EOT

If you upgrade TLJH later, re-run this script so the skeleton-folder patch
in step 6 is applied again.
EOT
}

notes=$(admin_notes)
echo
printf '%s\n' "$notes"
sudo install -d -m 0755 -o root -g root "$NOTES_DIR"
printf '%s\n' "$notes" | sudo tee "$NOTES_FILE" >/dev/null
sudo chmod 0644 "$NOTES_FILE"
sudo ln -sfn "$(basename -- "$NOTES_FILE")" "$NOTES_DIR/latest.txt"
echo
echo "These notes were saved to $NOTES_FILE (the newest is always $NOTES_DIR/latest.txt)."
