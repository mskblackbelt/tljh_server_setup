# CMake initial cache for the GROMACS build (passed as `cmake -C <this file>`).
# Used by tljh-install-gromacs; see gromacs_build.conf for the version, paths
# and CUDA toolkit. The install prefix and CUDA paths are added on the cmake
# command line by the script.
#
# Option reference: https://manual.gromacs.org/current/install-guide/

set(CMAKE_BUILD_TYPE Release CACHE STRING "")

# Mixed precision, thread-MPI: one `gmx` program, the right build for a single
# workstation-class machine. (No GMX_MPI / GMX_DOUBLE builds.)
set(GMX_DOUBLE OFF CACHE BOOL "")
set(GMX_MPI    OFF CACHE BOOL "")
set(GMX_OPENMP ON  CACHE BOOL "")

# GPU: NVIDIA RTX 4000 Ada = compute capability 8.9. Building only for it keeps
# the build shorter and avoids architectures newer CUDA versions dropped.
set(GMX_GPU CUDA CACHE STRING "")
set(CMAKE_CUDA_ARCHITECTURES 89 CACHE STRING "")

# CPU: Threadripper PRO 7975WX (Zen 4). The install guide recommends AVX_512
# on AMD from Zen 4 on, while noting AVX2_256 can be faster on Zen with GPU
# offload. Change to AVX2_256 here if benchmarks favor it.
set(GMX_SIMD AVX_512 CACHE STRING "")

# FFT: build a SIMD-enabled FFTW for CPU FFTs (downloaded from fftw.org during
# the build). GPU FFTs use cuFFT from the CUDA toolkit.
set(GMX_FFT_LIBRARY fftw3 CACHE STRING "")
set(GMX_BUILD_OWN_FFTW ON CACHE BOOL "")

# Better run-time hardware detection (needs libhwloc-dev).
set(GMX_HWLOC ON CACHE BOOL "")

# Needed by the gmxapi Python package (both are GROMACS defaults).
set(GMXAPI ON CACHE BOOL "")
set(BUILD_SHARED_LIBS ON CACHE BOOL "")

# Keep the installed binaries finding their libraries without LD_LIBRARY_PATH.
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH ON CACHE BOOL "")
