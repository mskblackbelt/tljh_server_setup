# resource_groups.py - CPU, memory and GPU for users' servers, by hub group.
#
# Installed by scripts/tljh_server_setup.sh (step 7) into
#   /opt/tljh/config/jupyterhub_config.d/
# which TLJH loads after its own settings. Apply changes with:
#   sudo tljh-config reload hub
# Each user gets the new settings the next time their server starts.
#
# Everyone gets TLJH's defaults (`tljh-config set limits.cpu 4` and
# `limits.memory 8G`), and no GPU. Members of the hub groups below get more.
# A user in several groups gets the largest CPU and the largest memory of
# them. CPUs are logical CPUs (threads): this machine has 64 on 32 physical
# cores. Limits are ceilings, not reservations.
#
# Managing members: Admin page (/hub/admin), "Groups". Use hub usernames
# (e.g. dwheeler), not Linux ones (jupyter-dwheeler). These hub groups are
# separate from the Linux group jupyterhub-instructors used for drop boxes.
# This file only creates the groups; it never adds or removes members.

import os

c = get_config()  # noqa: F821

# Hub group -> limits for that group's servers. Edit freely; a new name here
# creates a new (empty) group at the next hub restart.
RESOURCE_GROUPS = {
    "instructors": {"cpu_limit": 8, "mem_limit": "16G"},   # testing course material
    "research": {"cpu_limit": 16, "mem_limit": "32G"},
}

# Members of this group can use the GPU; everyone else's server has no
# access to it (systemd PrivateDevices: a private /dev holding only basic
# devices, terminals and shared memory).
GPU_GROUP = "gpu"

# Set OMP_NUM_THREADS (and Gaussian's default processor count and memory)
# to match each server's limits. Without it, OpenMP programs (numpy/BLAS,
# Psi4, ...) start one thread per logical CPU (64) and then crawl under a
# 4-CPU limit.
SET_THREAD_DEFAULTS = True


# --- Implementation ---------------------------------------------------------

_UNITS = {"K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}


def _bytes(size):
    """'16G' -> bytes (ints pass through)."""
    if isinstance(size, (int, float)):
        return int(size)
    size = str(size).strip().upper().rstrip("B")
    if size and size[-1] in _UNITS:
        return int(float(size[:-1]) * _UNITS[size[-1]])
    return int(size)


def _group_overrides(spawner):
    """Overrides for this user, from the hub groups they're in.

    A callable, so a user in several groups gets the maximum of each limit
    rather than whatever group happens to sort last.
    """
    mine = {g.name for g in spawner.user.groups}
    overrides = {}

    matched = sorted(mine & RESOURCE_GROUPS.keys())
    if matched:
        limits = [RESOURCE_GROUPS[g] for g in matched]
        override = {}
        cpus = [l["cpu_limit"] for l in limits if "cpu_limit" in l]
        if cpus:
            override["cpu_limit"] = float(max(cpus))
        mems = [l["mem_limit"] for l in limits if "mem_limit" in l]
        if mems:
            override["mem_limit"] = max(mems, key=_bytes)
        overrides["10-resources"] = {"groups": matched, "spawner_override": override}

    if GPU_GROUP in mine:
        overrides["20-gpu"] = {
            "groups": [GPU_GROUP],
            "spawner_override": {"isolate_devices": False},
        }
    return overrides


c.JupyterHub.load_groups = {name: {"users": []} for name in [*RESOURCE_GROUPS, GPU_GROUP]}
c.Spawner.group_overrides = _group_overrides
c.SystemdSpawner.isolate_devices = True     # no GPU unless in GPU_GROUP


if SET_THREAD_DEFAULTS:
    # Values are functions, evaluated when each server starts, after the
    # group overrides above have been applied.
    def _threads(spawner):
        return str(max(1, int(spawner.cpu_limit or os.cpu_count() or 1)))

    def _gaussian_mem(spawner):
        # 75% of the server's memory limit, leaving room for Python etc.
        if not spawner.mem_limit:
            return "4GB"
        return f"{max(1, int(spawner.mem_limit * 0.75 / 1024**3))}GB"

    env = {"OMP_NUM_THREADS": _threads}
    # Overrides GAUSS_PDEF/GAUSS_MDEF from gaussian.py (this file loads after
    # it: TLJH loads these files in alphabetical order).
    if os.path.exists("/opt/gaussian/g16"):
        env.update({"GAUSS_PDEF": _threads, "GAUSS_MDEF": _gaussian_mem})
    c.Spawner.environment.update(env)
