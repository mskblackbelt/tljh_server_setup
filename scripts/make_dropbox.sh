#!/usr/bin/env bash
# Re-run under bash if started with `sh script`.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
#
# tljh-make-dropbox - Create (or repair) an instructor's submission drop box
# under /srv/shared/submissions. (Source: scripts/make_dropbox.sh in the
# setup repo; tljh_server_setup.sh installs it to /usr/local/sbin.)
#
# Usage:
#   sudo tljh-make-dropbox [--dry-run] [--fix-files] <folder> <instructor>
#
# Who can run it:
#   admins       any folder, any instructor
#   instructors  only for themselves (<instructor> must be their own
#                account), and only folders they already own or new ones
#
#   <folder>      Folder name, e.g. dwheeler_357_sp26, or its full path
#                 /srv/shared/submissions/dwheeler_357_sp26. It must sit
#                 directly inside /srv/shared/submissions.
#   <instructor>  The instructor's hub account, e.g. jupyter-dwheeler. The
#                 account exists only after they have logged in once.
#   --fix-files   Also lock down files already in the folder (see below).
#   --dry-run     Print the commands without running them.
#
# Resulting permissions on the folder:
#   owner           instructor             full access
#   instructors     jupyterhub-instructors full access
#   students        jupyterhub-users       can list the folder and add files
#   everyone else   no access
#   setgid          new files belong to jupyterhub-instructors
#   sticky          students can't delete or rename other people's files
#
# Students can browse the folder in JupyterLab and see every file NAME, but
# can open only their own files. Each new file gets: its owner (the student)
# read/write, instructors read/write, other students no access. This holds
# for files saved, uploaded or copied in from JupyterLab, and for cp, cp -p
# and cp -a in a terminal.
#
# One exception: `mv` from a home folder on the SAME filesystem keeps the
# file's old permissions, which usually let anyone read it. Keep /home and
# /srv on separate ZFS datasets (then mv copies instead), and/or re-run with
# --fix-files, which re-applies the rules above to every file and folder
# already inside. A student can always choose to open up their own file
# (they own it); these rules prevent accidents, not deliberate sharing.
#
# Safe to re-run: it resets the folder's own permissions. Files inside are
# changed only with --fix-files.

set -euo pipefail
trap 'echo "error: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

BASE=/srv/shared/submissions
STUDENTS_GROUP=jupyterhub-users          # TLJH puts every hub user in this group
INSTRUCTORS_GROUP=jupyterhub-instructors

usage() { sed -n '5,/^$/s/^# \{0,1\}//p' "$0"; }
die()   { echo "error: $*" >&2; exit 1; }

DRY_RUN=0 FIX_FILES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=1; shift ;;
        --fix-files) FIX_FILES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*)        die "unknown option: $1 (see --help)" ;;
        *)         break ;;
    esac
done
[[ $# -eq 2 ]] || die "expected <folder> <instructor> (see --help)"
FOLDER_ARG=$1
INSTRUCTOR=$2

# --- Validate the tools and groups ---------------------------------------------

[[ $DRY_RUN -eq 1 || $EUID -eq 0 ]] || die "run with sudo"
command -v setfacl >/dev/null || die "setfacl not found; install it with: sudo apt-get install acl"
for g in "$STUDENTS_GROUP" "$INSTRUCTORS_GROUP"; do
    getent group "$g" >/dev/null || die "group '$g' does not exist (create it with: sudo groupadd $g)"
done

# --- Validate the base folder -------------------------------------------------------

[[ -d "$BASE" && ! -L "$BASE" ]] || die "$BASE is missing or is a symlink; run tljh_server_setup.sh first"

# POSIX ACLs are off by default on ZFS datasets.
if [[ "$(findmnt -no FSTYPE --target "$BASE")" == zfs ]]; then
    dataset=$(findmnt -no SOURCE --target "$BASE")
    acltype=$(zfs get -H -o value acltype "$dataset")
    [[ "$acltype" == posix || "$acltype" == posixacl ]] \
        || die "ZFS dataset '$dataset' has acltype=$acltype. Enable ACLs with:
    sudo zfs set acltype=posix xattr=sa $dataset"
fi

# --- Validate the folder name ---------------------------------------------------------

if [[ "$FOLDER_ARG" == */* ]]; then
    # A path: it must resolve to a folder directly inside $BASE.
    FOLDER=$(realpath -m -- "$FOLDER_ARG")
    [[ "$(dirname -- "$FOLDER")" == "$BASE" ]] \
        || die "'$FOLDER_ARG' is not directly inside $BASE"
    NAME=$(basename -- "$FOLDER")
else
    NAME=$FOLDER_ARG
    FOLDER="$BASE/$NAME"
fi
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "invalid folder name '$NAME' (letters, digits, '.', '_' or '-'; must not start with '.' or '-')"
[[ ! -L "$FOLDER" ]] || die "$FOLDER is a symlink; refusing to change it"
[[ ! -e "$FOLDER" || -d "$FOLDER" ]] || die "$FOLDER exists and is not a folder"

# --- Validate the instructor --------------------------------------------------------------

[[ "$INSTRUCTOR" =~ ^jupyter-[a-z0-9][a-z0-9._-]*$ && ${#INSTRUCTOR} -le 32 ]] \
    || die "invalid instructor '$INSTRUCTOR' (expected a hub account such as jupyter-dwheeler)"
getent passwd "$INSTRUCTOR" >/dev/null \
    || die "user '$INSTRUCTOR' does not exist. Hub accounts are created at first login; have them log in once."
if ! id -nG "$INSTRUCTOR" | tr ' ' '\n' | grep -qx "$INSTRUCTORS_GROUP"; then
    echo "warning: $INSTRUCTOR is not in $INSTRUCTORS_GROUP. They still own this folder," >&2
    echo "         but add them with: sudo usermod -aG $INSTRUCTORS_GROUP $INSTRUCTOR" >&2
fi

# --- Check who is asking -----------------------------------------------------------
# Instructors reach this script through a sudo rule
# (/etc/sudoers.d/jupyterhub-instructors). sudo sets SUDO_USER to the real
# caller, and it can't be faked from inside sudo. Non-admins may only act on
# their own drop boxes.

CALLER=${SUDO_USER:-root}
if [[ "$CALLER" != root ]] && ! id -nG "$CALLER" | tr ' ' '\n' | grep -qx jupyterhub-admins; then
    [[ "$INSTRUCTOR" == "$CALLER" ]] \
        || die "you can only create drop boxes for yourself ($CALLER), not $INSTRUCTOR"
    if [[ -d "$FOLDER" ]]; then
        owner=$(stat -c %U "$FOLDER")
        [[ "$owner" == "$CALLER" ]] \
            || die "$FOLDER belongs to $owner; ask a hub admin to change it"
    fi
fi

# --- Create and set permissions ------------------------------------------------------------

# Students get rwx on the folder itself (list + add files).
ACL="u::rwx,g::rwx,o::---,g:$STUDENTS_GROUP:rwx,g:$INSTRUCTORS_GROUP:rwx,m::rwx"
# New files and subfolders inherit these. The explicit `jupyterhub-users:---`
# entry is what keeps classmates out even when a copy brings along
# world-readable permissions (cp -p, cp -a, JupyterLab's copy): a named-group
# entry overrides "other". Instructors are in both groups, and Linux grants
# access if ANY of a user's matching group entries allows it, so they keep
# read/write.
DEFAULT_ACL="d:u::rwx,d:g::rwx,d:o::---,d:g:$STUDENTS_GROUP:---,d:g:$INSTRUCTORS_GROUP:rwx,d:m::rwx"
# Applied to existing contents by --fix-files. rwX = execute only on folders.
CONTENT_ACL="o::---,g:$STUDENTS_GROUP:---,g:$INSTRUCTORS_GROUP:rwX"

run() {
    printf '  $'; printf ' %q' "$@"; printf '\n'
    if [[ $DRY_RUN -eq 0 ]]; then "$@"; fi
}

# Order matters on an existing folder: nothing below ever removes the
# setgid/sticky bits, so an interrupted run can't leave the drop box open.
if [[ -d "$FOLDER" ]]; then
    echo "==> $FOLDER exists; resetting its permissions (files inside are not changed)"
    run chown "$INSTRUCTOR:$INSTRUCTORS_GROUP" "$FOLDER"
else
    echo "==> Creating $FOLDER"
    run install -d -o "$INSTRUCTOR" -g "$INSTRUCTORS_GROUP" -m 0770 "$FOLDER"
fi
run chmod 3770 "$FOLDER"                           # setgid + sticky
run setfacl --set "$ACL,$DEFAULT_ACL" "$FOLDER"

if [[ $FIX_FILES -eq 1 ]]; then
    echo "==> Locking down existing contents of $FOLDER"
    # -P: never follow symlinks, so a student can't point a link at a file
    # elsewhere on the system and have root change its permissions.
    # Only real files and folders are touched (find does not follow links).
    run find "$FOLDER" -mindepth 1 \( -type f -o -type d \) \
        -exec setfacl -P -m "$CONTENT_ACL" {} +
    run find "$FOLDER" -mindepth 1 -type d \
        -exec setfacl -P -m "$DEFAULT_ACL" {} +
fi

if [[ $DRY_RUN -eq 0 ]]; then
    echo "==> Result:"
    getfacl -p "$FOLDER"
fi
