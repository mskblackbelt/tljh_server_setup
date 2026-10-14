# Gaussian 16 on the TLJH server — decisions (Oct 2026)

- Binary: G16 B.01, AVX2 (Haswell) build, supplied as AVX2.zip (Oct 2026). Replaces the older Nehalem/SSE4.2 B.01 build (folder g16_b01); the server's Zen 4 CPU supports AVX2. C.02 is the newer revision if ever needed. The RTX 4000 Ada isn't supported by G16 GPU code.
- Installer: scripts/install_gaussian.sh -> /usr/local/sbin/tljh-install-gaussian (step 11 of 13 in tljh_server_setup.sh; optional prompt for the files' path).
- Layout: g16root=/opt/gaussian (files in /opt/gaussian/g16), root:jupyterhub-users, 750/640, no access for others. Every hub account is in jupyterhub-users; other accounts need `usermod -aG jupyterhub-users`.
- Scratch: /scratch/g16 (3770, tmpfiles cleanup of files >7 days). Its own ZFS dataset, tank/scratch/g16, created by step 1 of tljh_server_setup.sh.
- Environment: /opt/tljh/config/jupyterhub_config.d/gaussian.py (Spawner.environment; PATH appended) for notebooks + JupyterLab terminals; /etc/profile.d/gaussian.sh for SSH.
- Defaults for jobs without %mem / %nproc: the installer writes GAUSS_MDEF=6GB, GAUSS_PDEF=4 (its --mem/--nproc options). On the hub, config/jupyterhub_config.d/resource_groups.py (SET_THREAD_DEFAULTS) replaces them per server: GAUSS_PDEF = the server's CPU limit, GAUSS_MDEF = 75% of its memory limit (default 4 / 6GB; instructors 8 / 12GB; research 16 / 24GB). SSH logins keep the installer's values. GAUSS_CDEF avoided (pins all users to the same cores).
- Access: every hub account (group jupyterhub-users) can run Gaussian; a separate `gaussian` group was considered and not used. Revisit only if SSH-only or non-hub users come up (a `--group` option plus TLJH's users.extra_user_groups). Gaussian doesn't use the GPU, so the hub's `gpu` group doesn't affect it.
- Long jobs: a job started from a user's server stops if that server is stopped, and the 1-hour idle shutdown may stop a server whose job prints nothing (to be checked; see Testing). Slurm, planned for later, would run long jobs independently.
- Testing: see the "Gaussian 16" checks in server_setup.md, section Testing.
- Installer runs test0000 as an ordinary group member and compares the energy to the reference (-74.9607232751).
