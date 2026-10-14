#!/usr/bin/env bash
# Re-run under bash if started with `sh script`.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
#
# tljh-install-gromacs - Build GROMACS from source with CUDA (GPU) support and
# make it available to every JupyterHub user: notebooks, JupyterLab
# terminals and SSH. Optionally adds the gmxapi Python package to a course
# kernel. (Source: scripts/install_gromacs.sh in the setup repo;
# tljh_server_setup.sh installs it to /usr/local/sbin.)
#
# Usage:
#   sudo tljh-install-gromacs [options]
#
# Options:
#   -c, --config FILE  Build settings (default:
#                      /usr/local/etc/tljh/gromacs_build.conf). Its folder
#                      must also hold the CMake cache file it names.
#   --gmxapi-only      Only (re)install gmxapi into the course kernel env
#                      (e.g. after that env was rebuilt).
#   --skip-tests       Don't run `make check` (unit + regression tests).
#   --keep-build       Keep the build folder and downloads afterwards.
#   --no-reload        Don't restart the hub at the end.
#   --dry-run          Show the settings and the main commands; change nothing.
#   -h, --help         Show this help.
#
# What it does:
#   1. Checks the NVIDIA driver (must already be installed) and installs the
#      CUDA toolkit from NVIDIA's apt repository if it's missing.
#   2. Installs build tools (compilers, cmake, hwloc).
#   3. Downloads GROMACS and its regression tests, checking their MD5 sums.
#   4. Builds GROMACS, runs its tests, and installs it in
#      /opt/gromacs/<version>; /opt/gromacs/current points to it. Older
#      versions are left in place.
#   5. Puts `gmx` on every user's PATH (notebooks, JupyterLab terminals, SSH).
#   6. Builds gmxapi from the same GROMACS source into the course kernel env.
#   7. Checks `gmx` and gmxapi as an ordinary user.
#
# Expect roughly 20-60 minutes, mostly the build and the tests. A full log
# goes to /var/log/tljh-install-gromacs-<version>.log.

set -euo pipefail
trap 'echo "error: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

CONFIG=/usr/local/etc/tljh/gromacs_build.conf
TLJH_USER=/opt/tljh/user
HUB_SNIPPET=/opt/tljh/config/jupyterhub_config.d/gromacs.py
PROFILE_SNIPPET=/etc/profile.d/gromacs.sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

usage() { sed -n '5,/^$/s/^# \{0,1\}//p' "$0"; }
die()   { echo "error: $*" >&2; exit 1; }
info()  { echo "==> $*"; }

DRY_RUN=0 RELOAD=1 TESTS=1 KEEP_BUILD=0 GMXAPI_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)   CONFIG=${2:?"--config needs a file"}; shift 2 ;;
        --gmxapi-only) GMXAPI_ONLY=1; shift ;;
        --skip-tests)  TESTS=0; shift ;;
        --keep-build)  KEEP_BUILD=1; shift ;;
        --no-reload)   RELOAD=0; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown argument: $1 (see --help)" ;;
    esac
done

# --- Settings ----------------------------------------------------------------------

[[ $DRY_RUN -eq 1 || $EUID -eq 0 ]] || die "run with sudo"
[[ -f "$CONFIG" ]] || die "config file not found: $CONFIG"
CONFIG=$(realpath -- "$CONFIG")
CONFIG_DIR=$(dirname -- "$CONFIG")
# The config is run as bash (as root), so it must not be editable by others.
if [[ $DRY_RUN -eq 0 ]]; then
    [[ "$(stat -c %u "$CONFIG")" == 0 ]] || die "$CONFIG must be owned by root"
fi
[[ $(( 8#$(stat -c %a "$CONFIG") & 8#022 )) -eq 0 ]] \
    || die "$CONFIG must not be writable by group or others"
# shellcheck source=/dev/null
. "$CONFIG"
for v in GMX_VERSION GMX_URL GMX_MD5 REGRESSIONTEST_URL REGRESSIONTEST_MD5 GMX_ROOT \
         BUILD_ROOT CMAKE_CACHE_FILE CUDA_VERSION CUDA_KEYRING_URL CUDA_HOME CUDA_APT_PACKAGE; do
    [[ -n "${!v:-}" ]] || die "$v is not set in $CONFIG"
done
GMXAPI_ENV=${GMXAPI_ENV:-}
[[ "$GMX_VERSION" =~ ^[0-9]{4}(\.[0-9]+)*$ ]] || die "GMX_VERSION looks wrong: $GMX_VERSION"
[[ "$GMX_ROOT" == /* && "$GMX_ROOT" != / ]] || die "GMX_ROOT must be an absolute path"
[[ "$BUILD_ROOT" == /* && "$BUILD_ROOT" != / ]] || die "BUILD_ROOT must be an absolute path"
[[ "$CMAKE_CACHE_FILE" == /* ]] || CMAKE_CACHE_FILE="$CONFIG_DIR/$CMAKE_CACHE_FILE"
[[ -f "$CMAKE_CACHE_FILE" ]] || die "CMake cache file not found: $CMAKE_CACHE_FILE"

PREFIX="$GMX_ROOT/$GMX_VERSION"
SRC_DIR="$GMX_ROOT/src/gromacs-$GMX_VERSION"      # kept: gmxapi builds from it
BUILD_DIR="$BUILD_ROOT/$GMX_VERSION"
DL_DIR="$BUILD_ROOT/downloads"
LOG="/var/log/tljh-install-gromacs-$GMX_VERSION.log"
JOBS=$(nproc)
ENV_PREFIX=""
[[ -z "$GMXAPI_ENV" ]] || ENV_PREFIX="$TLJH_USER/envs/$GMXAPI_ENV"

cat <<EOF
GROMACS $GMX_VERSION
  install to   : $PREFIX  (linked as $GMX_ROOT/current)
  build options: $CMAKE_CACHE_FILE
  CUDA toolkit : $CUDA_HOME ($CUDA_APT_PACKAGE)
  gmxapi into  : ${ENV_PREFIX:-(skipped)}
  tests        : $([[ $TESTS -eq 1 ]] && echo "make check" || echo skipped)
EOF

if [[ $DRY_RUN -eq 1 ]]; then
    cat <<EOF

Dry run. Main commands:
  apt-get install -y build-essential cmake libhwloc-dev hwloc curl ca-certificates
  curl -fL $GMX_URL   (MD5 $GMX_MD5)
  curl -fL $REGRESSIONTEST_URL   (MD5 $REGRESSIONTEST_MD5)
  cmake -S $SRC_DIR -B $BUILD_DIR -C $CMAKE_CACHE_FILE \\
        -DCMAKE_INSTALL_PREFIX=$PREFIX -DREGRESSIONTEST_PATH=<tests> \\
        -DCUDAToolkit_ROOT=$CUDA_HOME -DCMAKE_CUDA_COMPILER=$CUDA_HOME/bin/nvcc \\
        -DCMAKE_C_COMPILER=/usr/bin/gcc -DCMAKE_CXX_COMPILER=/usr/bin/g++ \\
        -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++
  make -C $BUILD_DIR -j$JOBS && make -C $BUILD_DIR -j$JOBS check && make -C $BUILD_DIR install
  ln -sfn $GMX_VERSION $GMX_ROOT/current
  write $HUB_SNIPPET and $PROFILE_SNIPPET
  gmxapi_ROOT=$PREFIX $ENV_PREFIX/bin/python -m pip install --no-cache-dir $SRC_DIR/python_packaging/gmxapi
EOF
    exit 0
fi

# Everything below is logged.
exec > >(tee -a "$LOG") 2>&1
echo "---- $(date -Is) tljh-install-gromacs $*"

# --- gmxapi --------------------------------------------------------------------------
# Built from the matching GROMACS source rather than PyPI, whose gmxapi
# release (0.4.2, 2023) predates this GROMACS. pip builds it with the system
# compiler that built GROMACS.

install_gmxapi() {
    [[ -n "$ENV_PREFIX" ]] || { info "gmxapi: skipped (GMXAPI_ENV is empty)"; return 0; }
    [[ -x "$ENV_PREFIX/bin/python" ]] \
        || die "conda env $ENV_PREFIX not found; build it first (tljh-install-kernel), then run: sudo tljh-install-gromacs --gmxapi-only"
    [[ -d "$SRC_DIR/python_packaging/gmxapi" ]] \
        || die "$SRC_DIR/python_packaging/gmxapi not found; run tljh-install-gromacs without --gmxapi-only"
    [[ -x "$PREFIX/bin/gmx" ]] || die "GROMACS $GMX_VERSION is not installed in $PREFIX"
    info "Building gmxapi into $ENV_PREFIX"
    # env -i: nothing from root's environment (conda, pip settings) leaks in,
    # except proxy and CA-certificate settings (kept by `sudo -E`).
    env -i PATH="$PREFIX/bin:$ENV_PREFIX/bin:/usr/bin:/bin" HOME=/root \
        ${http_proxy:+"http_proxy=$http_proxy"} ${https_proxy:+"https_proxy=$https_proxy"} \
        ${HTTP_PROXY:+"HTTP_PROXY=$HTTP_PROXY"} ${HTTPS_PROXY:+"HTTPS_PROXY=$HTTPS_PROXY"} \
        ${no_proxy:+"no_proxy=$no_proxy"} ${PIP_CERT:+"PIP_CERT=$PIP_CERT"} \
        ${SSL_CERT_FILE:+"SSL_CERT_FILE=$SSL_CERT_FILE"} \
        ${REQUESTS_CA_BUNDLE:+"REQUESTS_CA_BUNDLE=$REQUESTS_CA_BUNDLE"} \
        CC=/usr/bin/gcc CXX=/usr/bin/g++ gmxapi_ROOT="$PREFIX" \
        "$ENV_PREFIX/bin/python" -m pip install --no-cache-dir --upgrade \
        "$SRC_DIR/python_packaging/gmxapi"
    info "Checking gmxapi as an ordinary user"
    runuser -u nobody -- env -i PATH="$GMX_ROOT/current/bin:/usr/bin:/bin" HOME=/tmp \
        "$ENV_PREFIX/bin/python" -c 'import gmxapi; print("gmxapi", gmxapi.__version__, "OK")' \
        || die "gmxapi installed but won't import (see above). A libstdc++ 'GLIBCXX' error means the env's libstdc++ is older than the system compiler's; add libstdcxx>=15 to the env file and rebuild it."
}

if [[ $GMXAPI_ONLY -eq 1 ]]; then
    install_gmxapi
    exit 0
fi

# --- 1. NVIDIA driver and CUDA toolkit ------------------------------------------------

info "Checking the NVIDIA driver"
if ! { command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null; }; then die "the NVIDIA driver isn't working (nvidia-smi failed). Install it first, e.g.
    sudo ubuntu-drivers install    # or: sudo apt-get install nvidia-open
and reboot, then re-run."; fi
nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader
drv_cuda=$(nvidia-smi | grep -o 'CUDA Version: [0-9.]*' | awk '{print $3}')
if [[ -n "$drv_cuda" ]]; then
    if [[ "${drv_cuda%%.*}" -lt "${CUDA_VERSION%%.*}" ]]; then
        die "the driver supports CUDA up to $drv_cuda, older than toolkit $CUDA_VERSION; update the NVIDIA driver"
    elif [[ "$(printf '%s\n%s\n' "$drv_cuda" "$CUDA_VERSION" | sort -V | head -1)" != "$CUDA_VERSION" ]]; then
        echo "warning: driver supports CUDA $drv_cuda, toolkit is $CUDA_VERSION (works via minor-version compatibility; a driver update is better)"
    fi
fi

if [[ ! -x "$CUDA_HOME/bin/nvcc" ]]; then
    info "Installing CUDA toolkit $CUDA_VERSION from NVIDIA's repository"
    if dpkg -s nvidia-cuda-toolkit >/dev/null 2>&1; then
        echo "warning: Ubuntu's nvidia-cuda-toolkit package is also installed; it can shadow NVIDIA's nvcc. This build uses $CUDA_HOME explicitly."
    fi
    if ! dpkg -s cuda-keyring >/dev/null 2>&1; then
        kr=$(mktemp --suffix=.deb)
        curl -fsSL -o "$kr" "$CUDA_KEYRING_URL" \
            || die "couldn't download $CUDA_KEYRING_URL (check CUDA_REPO_DISTRO in $CONFIG)"
        dpkg -i "$kr"; rm -f -- "$kr"
    fi
    apt-get update
    apt-get install -y "$CUDA_APT_PACKAGE"
fi
[[ -x "$CUDA_HOME/bin/nvcc" ]] || die "nvcc not found at $CUDA_HOME/bin/nvcc"
"$CUDA_HOME/bin/nvcc" --version | tail -2

# --- 2. Build tools ------------------------------------------------------------------

info "Installing build tools"
apt-get install -y build-essential cmake libhwloc-dev hwloc curl ca-certificates
cmake_ver=$(cmake --version | awk 'NR==1{print $3}')
[[ "$(printf '%s\n3.28\n' "$cmake_ver" | sort -V | head -1)" == 3.28 ]] \
    || die "cmake $cmake_ver is too old; GROMACS $GMX_VERSION needs 3.28 or later"
if grep -q 'GMX_SIMD AVX_512' "$CMAKE_CACHE_FILE" && ! grep -qw avx512f /proc/cpuinfo; then
    die "this CPU has no AVX-512; set GMX_SIMD to AVX2_256 in $CMAKE_CACHE_FILE"
fi

# --- 3. Sources ----------------------------------------------------------------------

fetch() {   # fetch <url> <md5> -> prints the local path
    local url=$1 md5=$2 out="$DL_DIR/${1##*/}"
    if [[ ! -f "$out" ]] || ! echo "$md5  $out" | md5sum -c --status; then
        echo "downloading $url" >&2
        curl -fL --retry 3 -o "$out.part" "$url" >&2
        mv -- "$out.part" "$out"
    fi
    echo "$md5  $out" | md5sum -c --status || die "MD5 mismatch for $out (expected $md5)"
    echo "$out"
}

info "Downloading GROMACS $GMX_VERSION"
install -d -m 0755 "$BUILD_ROOT" "$DL_DIR" "$GMX_ROOT" "$GMX_ROOT/src"
gmx_tar=$(fetch "$GMX_URL" "$GMX_MD5")
rt_tar=""
[[ $TESTS -eq 0 ]] || rt_tar=$(fetch "$REGRESSIONTEST_URL" "$REGRESSIONTEST_MD5")

rm -rf -- "${SRC_DIR:?}" "${BUILD_DIR:?}"
tar -xzf "$gmx_tar" -C "$GMX_ROOT/src" --no-same-owner
[[ -f "$SRC_DIR/CMakeLists.txt" ]] || die "unexpected archive layout (no $SRC_DIR/CMakeLists.txt)"
RT_DIR=""
if [[ -n "$rt_tar" ]]; then
    tar -xzf "$rt_tar" -C "$BUILD_ROOT" --no-same-owner
    RT_DIR="$BUILD_ROOT/regressiontests-$GMX_VERSION"
    [[ -d "$RT_DIR" ]] || die "unexpected regression-test archive layout"
fi

# --- 4. Configure, build, test, install ----------------------------------------------

info "Configuring (options from $CMAKE_CACHE_FILE)"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" -G "Unix Makefiles" \
    -C "$CMAKE_CACHE_FILE" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_C_COMPILER=/usr/bin/gcc \
    -DCMAKE_CXX_COMPILER=/usr/bin/g++ \
    -DCUDAToolkit_ROOT="$CUDA_HOME" \
    -DCMAKE_CUDA_COMPILER="$CUDA_HOME/bin/nvcc" \
    -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++ \
    ${RT_DIR:+"-DREGRESSIONTEST_PATH=$RT_DIR"}

info "Building with $JOBS jobs"
make -C "$BUILD_DIR" -j"$JOBS"

if [[ $TESTS -eq 1 ]]; then
    info "Running the GROMACS tests (make check)"
    make -C "$BUILD_DIR" -j"$JOBS" check \
        || die "tests failed; nothing was installed. Build kept in $BUILD_DIR (see $BUILD_DIR/Testing/Temporary/LastTest.log)"
fi

info "Installing into $PREFIX"
rm -rf -- "${PREFIX:?}"
make -C "$BUILD_DIR" install
chown -R root:root "$PREFIX" "$SRC_DIR"
chmod -R u=rwX,go=rX "$PREFIX" "$SRC_DIR"

missing=$(ldd "$PREFIX/bin/gmx" | grep 'not found' || true)
[[ -z "$missing" ]] || die "gmx can't find some libraries:
$missing"

# Switch `current` atomically; older versions stay for rollback.
ln -sfn "$GMX_VERSION" "$GMX_ROOT/current.new"
mv -T -- "$GMX_ROOT/current.new" "$GMX_ROOT/current"

# --- 5. Environment for every user -------------------------------------------------
# GROMACS's bin/ is PREPENDED to users' PATH via SystemdSpawner.extra_paths
# (its commands don't clash with system ones). This also composes with the
# Gaussian snippet, which sets Spawner.environment["PATH"]. The GMX* variables
# match what GMXRC sets.

info "Hub environment ($HUB_SNIPPET)"
install -d -m 0755 "$(dirname "$HUB_SNIPPET")"
cat > "$HUB_SNIPPET" <<EOF
# Installed by tljh-install-gromacs. GROMACS for every user's server
# (notebooks and JupyterLab terminals). Uses $GMX_ROOT/current, so upgrades
# need no change here.
_gmx = "$GMX_ROOT/current"
c.SystemdSpawner.extra_paths.append(_gmx + "/bin")
c.Spawner.environment.update({
    "GMXBIN": _gmx + "/bin",
    "GMXLDLIB": _gmx + "/lib",
    "GMXMAN": _gmx + "/share/man",
    "GMXDATA": _gmx + "/share/gromacs",
    "GROMACS_DIR": _gmx,
})
EOF
chmod 0644 "$HUB_SNIPPET"

info "Login-shell environment for SSH ($PROFILE_SNIPPET)"
cat > "$PROFILE_SNIPPET" <<EOF
# Installed by tljh-install-gromacs. GROMACS for SSH logins; skipped where
# it's already set (JupyterLab terminals get it from the hub).
if [ -z "\${GMXBIN:-}" ] && [ -r "$GMX_ROOT/current/bin/GMXRC" ]; then
    . "$GMX_ROOT/current/bin/GMXRC"
fi
EOF
chmod 0644 "$PROFILE_SNIPPET"

# --- 6. gmxapi -------------------------------------------------------------------------

install_gmxapi

# --- 7. Check as an ordinary user ----------------------------------------------------

info "Checking gmx as an ordinary user"
ver=$(runuser -u nobody -- env -i PATH="$GMX_ROOT/current/bin:/usr/bin:/bin" HOME=/tmp \
      gmx -quiet --version 2>&1) || { echo "$ver"; die "gmx --version failed"; }
echo "$ver" | grep -E '^(GROMACS version|Precision|SIMD instructions|GPU support|CUDA compiler|CUDA driver|CUDA runtime):' || true
echo "$ver" | grep -q '^GPU support: *CUDA' || die "this gmx was built without CUDA support"

if [[ $KEEP_BUILD -eq 0 ]]; then
    rm -rf -- "${BUILD_ROOT:?}"     # build folder, regression tests, downloads
fi

# --- Apply -------------------------------------------------------------------------------

if [[ $RELOAD -eq 1 ]]; then
    info "Reloading the hub so new user servers get GROMACS on their PATH"
    tljh-config reload hub
fi

cat <<EOF

==> GROMACS $GMX_VERSION is installed in $PREFIX ($GMX_ROOT/current).
    Users get it the next time their server starts (File > Hub Control
    Panel > Stop My Server, then start it). Then, in a terminal:
        gmx mdrun -deffnm md -ntmpi 1 -ntomp \$OMP_NUM_THREADS
    or in a notebook cell:  !gmx ...
    mdrun counts all of the machine's logical CPUs, so give it the
    server's CPU limit explicitly (OMP_NUM_THREADS is set to that limit by
    jupyterhub_config.d/resource_groups.py). The GPU is visible only to
    members of the hub's "gpu" group.
EOF
[[ -z "$ENV_PREFIX" ]] || echo "    gmxapi: import gmxapi in the \"$GMXAPI_ENV\" kernel."
for d in "$GMX_ROOT"/[0-9]*; do
    [[ -d "$d" && "$d" != "$PREFIX" ]] && echo "    older version (delete when no longer needed): $d"
done
exit 0
