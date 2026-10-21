# Server setup

How the JupyterHub server is built: manual base-system steps (sections 1–3), then `scripts/tljh_server_setup.sh` for everything else. A **Testing** checklist is at the end of the setup sections.

## Base system (before TLJH)

Sections 1–3 are done by hand on the new server before running `scripts/tljh_server_setup.sh`. Section 4 is handled by the script. Hardware: AMD Threadripper PRO 7975WX (32 cores / 64 threads), 128 GB RAM, NVIDIA RTX 4000 Ada, one 256 GB SSD and two 12 TB HDDs.

Where things live:

| Path | Location | Notes |
| --- | --- | --- |
| `/` (OS, packages), `/opt` (TLJH, conda environments) | SSD, btrfs | No redundancy. Everything here can be rebuilt from this repo's scripts. |
| `/home` | ZFS `tank/home` | Student homes, per-user quotas, back up |
| `/srv` | ZFS `tank/srv` | Shared course data and drop boxes, back up |
| `/scratch` | ZFS `tank/scratch` | Temporary job files, no backups, auto-cleanup |

### 1. Install Ubuntu Server

- Ubuntu Server 26.04.1 LTS on the SSD.
- SSD layout: EFI partition and `/` as **btrfs** (chosen at install time). Use a swap file instead of a swap partition, so it can be resized later.
- The OS, packages, `/opt` (TLJH and conda environments) live on the SSD. Keep it under about 80% full.
- Root on ZFS was considered and not chosen. The Server installer has no ZFS option in its menus. ZFS root is only possible through an autoinstall file (`layout: zfs`), the Desktop installer (marked experimental) or a manual install. On a single SSD, ZFS can detect corruption but has no second copy to repair it from, so it gains little over btrfs here.
- Don't touch the two HDDs during the install. They become the ZFS mirror in step 3.
- Install the NVIDIA driver (R615 or later for CUDA 13.4; see "Before installing" under Running the setup script), then boot with **IOMMU passthrough** (below). Needed for anything that uses both GPUs together, GROMACS included.

#### IOMMU passthrough for the two GPUs

With the kernel's default IOMMU mode (translated DMA), copies directly between the two RTX 4000 Ada cards arrive corrupted: CUDA still reports peer access as available, there's no error, and the kernel log fills with `AMD-Vi: Event logged [IO_PAGE_FAULT ...]` from both GPUs. NVIDIA states that IOMMU-enabled peer-to-peer copies aren't supported on bare-metal Linux and recommends `iommu=pt` ([forum reply from NVIDIA staff](https://forums.developer.nvidia.com/t/issacsim-4-5-not-responding-and-input-output-memory-management-unit-iommu-warning/346191/6), [Maxine/Triton docs](https://docs.nvidia.com/maxine/triton/1.2.0/Appendices/PCIeMultiGPUSystems.html)). Found in Oct 2026: CUDA's `simpleP2P` sample returned `nan`, and GROMACS's multi-rank tests gave energies ~37% off; both passed after this change. Driver or toolkit updates aren't expected to help.

```bash
sudo nano /etc/default/grub          # add iommu=pt inside GRUB_CMDLINE_LINUX_DEFAULT="..."
sudo update-grub && sudo reboot
cat /proc/cmdline                    # includes iommu=pt
sudo dmesg | grep -i 'default domain'   # "Passthrough"
```

Check peer-to-peer with NVIDIA's sample (needs the CUDA toolkit; `tljh-install-gromacs` installs it, or check again after step 12):

```bash
git clone --depth 1 https://github.com/NVIDIA/cuda-samples.git ~/cuda-samples
cd ~/cuda-samples/cpp/0_Introduction/simpleP2P && mkdir -p build && cd build
cmake .. -DCMAKE_CUDA_ARCHITECTURES=89 -DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.4/bin/nvcc && make
./simpleP2P                          # "Test passed!"
sudo dmesg | grep -c IO_PAGE_FAULT   # 0
```

Passthrough only stops the IOMMU from checking ordinary device DMA, which matters for VMs with passed-through devices; this server runs none. `tljh-install-gromacs` refuses to build while the GPUs' DMA is translated (`--allow-iommu` overrides it and turns off GROMACS's direct GPU communication instead). Re-check `simpleP2P` after NVIDIA driver upgrades.

#### Driver and toolkit versions

`nvidia-smi`'s "CUDA Version" ("CUDA UMD Version" on newer drivers such as R615) is the newest CUDA the *driver* supports, not the installed toolkit. A driver older than the toolkit still runs code compiled ahead of time (GROMACS here), but anything that compiles GPU code at run time (PTX JIT: Numba, CuPy, NVRTC) fails with `CUDA_ERROR_UNSUPPORTED_PTX_VERSION` (error 222). Found Oct 2026: with the R595 driver (CUDA 13.2) and toolkit 13.4, cuda-samples' `dsl`, `simple` and `uvmlite` failed and `ptxjit` was waived; with R615 all 134 sample runs pass. Branches per toolkit are in NVIDIA's [CUDA release notes](https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html) (13.4 → R615, 13.3 → R610, 13.2 → R595); `tljh-install-gromacs` warns when the driver is older than the toolkit. After any driver change, reboot and re-check `simpleP2P` and `ctest` in the GROMACS build folder (or reinstall GROMACS).

### 2. Time sync (chrony)

Ubuntu 26.04 uses **chrony** instead of `systemd-timesyncd`, and its default time servers are Canonical's NTS servers.

Check the status:

```bash
timedatectl status
chronyc tracking
chronyc sources -v      # "Reach 0" and "LastRx -" on every source means no replies
```

**Known problem on the new server's subnet:** requests on UDP port 123 go out, but no replies come back. DNS, the TCP/4460 NTS key exchange and its TLS handshake all work. The old server, on a different subnet, gets replies normally. So this is a campus firewall issue. Ask Hunter/CUNY IT to allow UDP/123 return traffic or for an internal NTP server address.

To see it for yourself:

```bash
sudo tcpdump -i any udp port 123 -n     # terminal 1
sudo systemctl restart chrony           # terminal 2; replies show up as "In" lines
```

Temporary fix (set the clock by hand). The clock will drift, so don't leave it this way:

```bash
sudo timedatectl set-ntp false
sudo timedatectl set-time 'YYYY-MM-DD HH:MM:SS'
sudo hwclock --systohc
timedatectl status
```

Once IT gives you a server address:

```bash
echo "server <ntp-server> iburst" | sudo tee /etc/chrony/sources.d/campus.sources
sudo timedatectl set-ntp true
sudo systemctl enable --now chrony
sudo chronyc reload sources
chronyc sources -v      # Reach should climb above 0 within a few minutes
```

Status: _update this line when IT responds._

### 3. Storage: ZFS mirror on the HDDs

One pool, `tank`, mirrors both HDDs (about 10.9 TB usable). `tank` is just the pool's name; it's the conventional example name from Sun's original ZFS docs and could be anything. Datasets: `tank/home` (`/home`), `tank/srv` (`/srv`) and `tank/scratch` (`/scratch`); see section 4 for the last two. A mirror protects against a failed drive, not against deletion, so `/home` still needs a separate backup.

1. Install ZFS and find the disks. Always use `/dev/disk/by-id/` paths, because `/dev/sdX` letters can change between boots.

   ```bash
   sudo apt update && sudo apt install zfsutils-linux
   lsblk -o NAME,SIZE,SERIAL,MODEL
   ls -la /dev/disk/by-id/ | grep -v part
   sudo wipefs -a /dev/disk/by-id/<disk1>     # only if a disk has old partitions
   sudo wipefs -a /dev/disk/by-id/<disk2>
   ```

2. Create the mirrored pool. `ashift` sets the smallest block ZFS writes to each disk, as a power of two: 2^12 = 4096 bytes, matching the drives' 4K physical sectors. Many drives report 512-byte sectors for compatibility, so set it by hand. It **can't be changed** after the pool is created.

   ```bash
   sudo zpool create -o ashift=12 tank mirror \
     /dev/disk/by-id/<disk1> /dev/disk/by-id/<disk2>
   zpool status tank
   ```

3. Create the datasets and set the pool defaults. `/home` is mounted at a temporary location until the data is copied over.

   ```bash
   sudo zfs create -o mountpoint=/mnt/newhome tank/home
   sudo zfs create -o mountpoint=/scratch tank/scratch
   sudo zfs set compression=lz4 tank
   sudo zfs set atime=off tank/home
   ```

   You don't need to create `tank/srv` or adjust `tank/scratch` here. Step 1 of `tljh_server_setup.sh` does it (see section 4).

4. Move `/home` onto ZFS. The server was pre-launch with only the admin account, so one copy was enough. On a live server, stop JupyterHub first and do a final `rsync --delete` pass.

   ```bash
   sudo rsync -aHAX --info=progress2 /home/ /mnt/newhome/
   sudo diff -rq /home /mnt/newhome
   sudo mv /home /home.bak
   sudo zfs set mountpoint=/home tank/home
   sudo zfs mount tank/home
   ```

   If `mv` fails with "Device or resource busy", the btrfs install made `/home` its own subvolume mount. Check with `findmnt /home`. If it shows btrfs, remove the `/home` line from `/etc/fstab`, run `sudo umount /home`, then repeat the steps above.

   Test logins and permissions, and keep `/home.bak` for a few days before you delete it.

5. Per-user home quotas. These are automatic: step 1 of the setup script sets a **default quota** of 30G (`HOME_DEFAULT_QUOTA` at the top of the script) on `tank/home`. It applies to every user without a quota of their own, including accounts created later, so new hub users need no extra step. It needs OpenZFS 2.4 or later; the server has 2.4.1.

   The equivalent by hand, plus per-user changes (by Linux account name, `jupyter-<name>` for hub users):

   ```bash
   sudo zfs set defaultuserquota=30G tank/home          # everyone without their own quota
   sudo zfs set userquota@jupyter-<name>=50G tank/home  # one user gets more (or less)
   sudo zfs set userquota@jupyter-<name>=none tank/home # back to the default
   zfs userspace tank/home                              # usage and quotas
   ```

   The default also applies to admin accounts; give yours a larger quota if you keep big files in your home folder.

### 4. `/srv` and `/scratch` datasets (done by the setup script)

Step 1 of `scripts/tljh_server_setup.sh` creates these datasets, or updates existing ones to match its settings. It's safe to re-run. It never moves or deletes files: if `/srv` or `/scratch` already holds files that aren't on the right dataset, it stops and says what to do. The settings (`ZPOOL`, `SCRATCH_QUOTA`, `SCRATCH_MAX_AGE`, ...) are at the top of the script; change one and re-run to apply it.

| Dataset | Mount | Settings |
| --- | --- | --- |
| `tank/srv` | `/srv` | `acltype=posix xattr=sa` (`tljh-make-dropbox` needs ACLs), `atime=off`, `setuid=off devices=off` |
| `tank/scratch` | `/scratch` | `quota=3T` (so scratch can't fill the pool `/home` is on), `atime=on relatime=on`, `setuid=off devices=off`, `com.sun:auto-snapshot=false` |
| `tank/scratch/g16` | `/scratch/g16` | inherits from `tank/scratch`; `tljh-install-gaussian` sets 3770 permissions and 7-day cleanup |

Both datasets inherit lz4 compression from `tank`. The script also creates `/scratch/users` (1777, sticky like `/tmp`) with a `README.txt`, and the cleanup rule `/etc/tmpfiles.d/tljh-scratch.conf`:

```
d /scratch/users 1777 root root ~14d
```

The daily `systemd-tmpfiles-clean` timer deletes anything inside a user's folder untouched for 14 days. The `~` keeps the per-user folders themselves.

*Why atime is on for scratch:* the cleanup deletes a file only once its access, modify, change and creation times are all older than the limit. With `atime=off`, a file that is read but never written, such as a job input, would be deleted while it's still in use. `relatime` updates the access time at most once a day, so it adds little disk work.

Backups: leave scratch out.
- No snapshots. If you use sanoid, don't give `tank/scratch` a template.
- Don't replicate the whole pool with `zfs send -R tank`, because that includes scratch. Send `tank/home` and `tank/srv` one at a time.

After the script runs, check:

```bash
zfs get -r quota,atime,relatime,acltype,compression,com.sun:auto-snapshot tank/srv tank/scratch
systemctl list-timers systemd-tmpfiles-clean.timer
```

Then do the scratch write test in the [Testing](#testing) checklist.

## Running the setup script

`scripts/tljh_server_setup.sh` does everything after sections 1–3. It asks its questions first, then runs unattended. Expect 30–60 minutes (mostly TeX Live), plus 20–60 minutes if GROMACS is built. It's safe to re-run; every step checks what's already done.

Hardware it's tuned for: AMD Threadripper PRO 7975WX (32 cores, 64 threads), 128 GB RAM, NVIDIA RTX 4000 Ada.

### Before installing

- [ ] **Repo committed and on the server.** Commit the repo (the setup's notes record its version with `git describe`), then `git clone` it on the server, or copy the whole folder. If you copy from iCloud Drive, make sure every file is downloaded locally first, especially `config/jupyterhub_config.d/`, `templates/pchem/` and `environments/`.
- [ ] **Base system done** (sections 1–3 above): Ubuntu installed, the `tank` pool exists, and `/home` is on it.
- [ ] **Clock correct** (`timedatectl status`). NTP is waiting on IT (section 2), so set it by hand if needed. Downloads and certificate checks fail when the clock is far off.
- [ ] **Gaussian 16 (optional):** the Gaussian binary archive (currently the B.01 AVX2 build, `AVX2.zip`) is copied to the server. Note its path; the script asks for it.
- [ ] **GROMACS (optional):** the NVIDIA driver is installed, from the branch that matches the CUDA toolkit in `config/gromacs_build.conf` (CUDA 13.4 needs R615: `sudo apt install nvidia-driver-615-open`, then reboot), and `nvidia-smi` shows "CUDA UMD Version: 13.4" or later. Don't use `sudo ubuntu-drivers install` here; it may pick an older branch. Use Ubuntu's `nvidia-driver-*-open` packages (signed modules that follow kernel updates), not NVIDIA's `nvidia-open`/`cuda-drivers` from the CUDA repository; the two conflict. The server must also boot with `iommu=pt` (section 1). The script installs the CUDA toolkit itself.
- [ ] **Disk space on the SSD:** `df -h /` shows plenty free. TeX Live, the CUDA toolkit, the conda environments and the GROMACS build all go there; 60 GB or more free is a rough estimate, not a measured figure.
- [ ] **Outbound network:** `curl -I https://<host>` works for tljh.jupyter.org, github.com, pypi.org, conda.anaconda.org and cdn.playwright.dev, and for GROMACS also ftp.gromacs.org, www.fftw.org and developer.download.nvidia.com.
- [ ] **Hub not reachable from outside yet.** Admin names are approved automatically for whoever signs up first, and the hub serves plain HTTP until the DMZ proxy and HTTPS are set up.
- [ ] *(optional)* Snapshot home folders first: `sudo zfs snapshot tank/home@pre-tljh`.

### Running it

From your own admin account (not root), in the repo folder:

```bash
bash scripts/tljh_server_setup.sh
```

It asks for the TLJH admin username(s), a hub password for each admin (typed without echo; blank skips that admin), the path to the Gaussian files (blank skips Gaussian), and whether to build GROMACS, shows a summary, and asks to continue. At the end it prints notes (next steps, storage, admin commands), also saved in `/var/log/tljh_server_setup/latest.txt`.

| Step | What it does |
| --- | --- |
| 1 | Creates or updates the `/srv` and `/scratch` ZFS datasets (section 4) |
| 2 | System packages: curl, git, python3, acl, full TeX Live |
| 3 | Installs TLJH with the admin account(s). The login method (sign up, admins approve) is written before the hub first starts, so there's no window where anyone can claim an account. On sudo-rs (Ubuntu's default sudo), also replaces TLJH's `exempt_group` sudoers line, which sudo-rs rejects (see Admin commands) |
| 4 | Installs the admin commands (below) in `/usr/local/sbin`, GROMACS build settings in `/usr/local/etc/tljh`, and the sudo rule that lets instructors run `tljh-make-dropbox` |
| 5 | `/etc/skel-tljh` (new users' home template, with a `shared` link) and `/srv/shared/lab_data`, `/srv/shared/submissions` |
| 6 | Patches TLJH so new home folders are built from `/etc/skel-tljh` (re-run after TLJH upgrades) |
| 7 | Default limits, idle shutdown, `cron`/`at` limited to root and the admin running the script (`/etc/cron.allow`, `/etc/at.allow`), and the hub config files from `config/jupyterhub_config.d` |
| 8 | Updates conda, mamba and pip in `/opt/tljh/user` (TLJH's own Miniforge is from 2024), then JupyterLab extensions and settings (`environments/base_requirements.txt`, `config/jupyter_config.py`), WebPDF browser |
| 9 | Notebook templates (each folder in `templates/`) |
| 10 | Course kernels (`environments/*.yaml`, listed in `COURSE_KERNELS` at the top of the script) |
| 11 | Gaussian 16 (optional), via `tljh-install-gaussian` |
| 12 | GROMACS with CUDA (optional), via `tljh-install-gromacs` |
| 13 | Reloads the proxy and hub |

### While it runs

- **Run it inside `tmux` or `screen`.** It takes an hour or more, and a dropped SSH connection would kill it partway through (`tmux new -s setup`; reattach with `tmux attach -t setup`).
- **Consider answering "N" to GROMACS on the first run.** It's the least-tested part (CUDA 13, NVIDIA's repository address, gmxapi), and its build and tests take a while. A failure in step 11 or 12 no longer stops the run: it's logged in `/var/log/tljh_server_setup/failures-<timestamp>.log` and listed at the top of the final notes. Build it afterwards on its own with `sudo -E tljh-install-gromacs`. The same applies to Gaussian (`sudo tljh-install-gaussian <files>`) if you want to be extra careful, although its installer checks itself with a test job.
- **If something fails,** fix it and re-run the script. It's safe to re-run, but it repeats the long steps, and step 3 also upgrades TLJH.

### After it finishes

1. Log in as each admin whose password was set during setup; sign up immediately (`/hub/signup`) as any admin that was skipped.
2. Work through the [Testing](#testing) checklist below.

### Where things are installed

| Path | What | From the repo |
| --- | --- | --- |
| `/opt/tljh/user` | Environment that runs JupyterLab for everyone | `environments/base_requirements.txt` |
| `/opt/tljh/user/envs/<name>` | Course kernels (`pchem2`, `compchem`) | `environments/*.yaml` |
| `/opt/tljh/user/etc/jupyter/` | `jupyter_config.py` (export formats, cell tags), `jupyter_server_config.json` | `config/jupyter_config.py` |
| `/opt/tljh/user/share/jupyter/notebook_templates/` | Notebook templates | `templates/<folder>/` |
| `/opt/tljh/config/jupyterhub_config.d/` | Hub settings: `resource_groups.py`, `playwright.py` (from the repo); `gaussian.py`, `gromacs.py` (written by their installers) | `config/jupyterhub_config.d/` |
| `/opt/tljh/playwright` | Headless Chromium for WebPDF export | |
| `/etc/skel-tljh` | Template for new home folders | |
| `/srv/shared/lab_data` | Course data: instructors write, everyone reads | |
| `/srv/shared/submissions` | Drop boxes, one per instructor/course | |
| `/usr/local/sbin/tljh-*` | Admin commands | `scripts/*.sh` |
| `/usr/local/etc/tljh/` | GROMACS build settings | `config/gromacs_build.conf`, `config/gromacs_cache.cmake` |
| `/opt/gaussian/g16`, `/scratch/g16` | Gaussian 16 and its scratch | |
| `/opt/gromacs/<version>`, `/opt/gromacs/current` | GROMACS | |

### Admin commands

Run any of them with `--help` for details.

| Command | Who | Purpose |
| --- | --- | --- |
| `sudo -E tljh-install-kernel [-d "<label>"] <env-file>` | admins | Add or update a course kernel (`-r` rebuilds from scratch, `--remove <name>` deletes) |
| `sudo tljh-make-dropbox <folder> <instructor>` | admins; instructors for their own folders | Create or repair a submission drop box |
| `sudo tljh-install-gaussian <files>` | admins | Install or replace Gaussian 16 |
| `sudo -E tljh-install-gromacs` | admins | Build or upgrade GROMACS (`--gmxapi-only` re-adds the Python API to the compchem kernel; `--allow-iommu` builds without IOMMU passthrough, see section 1) |

**sudo-rs note.** Ubuntu's default `sudo` is now sudo-rs. It ignores `-E` (printing "preserving the entire environment is not supported, '-E' is ignored") and rejects TLJH's `Defaults exempt_group = jupyterhub-admins` line. Step 3 removes that line and installs `/etc/sudoers.d/jupyterhub-admins-path` (`Defaults:%jupyterhub-admins !secure_path`), so hub admins keep their own `PATH` under sudo and `sudo -E pip install ...` in a hub terminal still uses `/opt/tljh/user/bin/pip`. Other users keep `secure_path`. TLJH rewrites its sudoers file on every install or upgrade, so re-run the setup script after upgrading TLJH. To pass a specific variable through, use `sudo --preserve-env=VAR,...`.

## Users, limits and groups

- **Accounts:** people sign up at `/hub/signup` and an admin approves them at `/hub/authorize` (NativeAuthenticator). Admins are approved automatically. Each hub user `name` gets a Linux account `jupyter-name`, created at first login.
- **Admin passwords:** the setup asks for a hub password for each admin (at least 8 characters, not a common password) and stores it as NativeAuthenticator's own approved record (a bcrypt hash; the password itself is never written to disk or put on a command line). Those admins log in at `/hub/login` straight away. An admin skipped there must sign up at `/hub/signup` right after setup, before the hub is reachable from outside: admin usernames are approved automatically, so whoever signs up first under one becomes that admin. Change a password at `/hub/change-password`, or re-run the setup and enter a new one.
- **Scheduled jobs:** `cron` and `at` jobs run outside users' Jupyter servers (and so outside their limits and GPU restriction), so only accounts listed in `/etc/cron.allow` and `/etc/at.allow` may use them: root and the admin who ran the setup script. Add other admins by hand, one username per line.
- **Idle shutdown:** a server with no activity for 1 hour is stopped. Running kernels are lost; saved files are not.
- **Default limits:** 4 CPUs and 8 GB per user's server (`tljh-config set limits.cpu` / `limits.memory`). CPUs are logical CPUs (threads): the machine has 64 on 32 cores. Limits are ceilings, not reservations. Going over the memory limit kills that user's kernel.
- **Hub groups** (`config/jupyterhub_config.d/resource_groups.py`): members get more, and only the `gpu` group can use the GPU (everyone else's server has no GPU devices). A user in several groups gets the largest CPU and memory of them.

  | Hub group | CPUs | Memory | GPU |
  | --- | --- | --- | --- |
  | (everyone) | 4 | 8 GB | no |
  | `instructors` | 8 | 16 GB | no |
  | `research` | 16 | 32 GB | no |
  | `gpu` | – | – | yes |

  Add members on the Admin page (`/hub/admin`, "Groups") using hub usernames (`dwheeler`, not `jupyter-dwheeler`). Changes apply when the user's server next starts. To change the limits, edit `resource_groups.py`, re-run the script (or copy the file into `/opt/tljh/config/jupyterhub_config.d/`), then `sudo tljh-config reload hub`.
- **Thread defaults:** `SET_THREAD_DEFAULTS` in `resource_groups.py` sets `OMP_NUM_THREADS` (and Gaussian's default processors and memory) to each server's limits.
- **Instructors (Linux group):** for drop boxes and `lab_data`, instructors also need the Linux group: `sudo usermod -aG jupyterhub-instructors jupyter-<name>`. This is separate from the `instructors` hub group above.

## Software

- **Course kernels:** `pchem2` ("Python (PChem Lab)", Python 3.14, psi4, nglview, ir_visuals_widget) and `compchem` ("Python (CompChem)", Python 3.13, matmalib, py3Dmol, Open MPI + mpi4py for gmxapi; gmxapi added by the GROMACS installer, built with the env's `mpicxx`). The default Python kernel stays the TLJH environment.
- **Gaussian 16:** see [gaussian_setup_notes.md](gaussian_setup_notes.md). Every hub user can run `g16` from a terminal or notebook cell.
- **GROMACS 2026.4:** built from source with CUDA by `tljh-install-gromacs`; version and options in `config/gromacs_build.conf` and `config/gromacs_cache.cmake`. `gmx` is on every user's PATH; mdrun counts all 64 logical CPUs, so users should run `gmx mdrun -ntmpi 1 -ntomp $OMP_NUM_THREADS`.
- **Exports:** HTML, LaTeX, Markdown, Notebook, PDF (LaTeX), Python and WebPDF in "Save and Export Notebook As". Cells tagged `remove_cell`/`hide_cell`, `remove_input`/`hide_input` or `remove_output`/`hide_output` are left out of exports.

## Testing

None of this has been run on the new server yet. Work through these after the first run of the setup script (and again after major changes). Use a test student account for anything marked *(student)*, and delete it afterwards.

### Setup and storage

- [ ] The setup script finishes without errors, and `/var/log/tljh_server_setup/latest.txt` lists everything as installed.
- [ ] `zfs get -r quota,atime,relatime,acltype,compression,com.sun:auto-snapshot tank/srv tank/scratch` matches section 4, and `systemctl list-timers systemd-tmpfiles-clean.timer` shows the cleanup timer.
- [ ] *(student)* Scratch write test in a JupyterLab terminal: `mkdir -p /scratch/users/$USER && touch /scratch/users/$USER/write-test && ls -l /scratch/users/$USER`. On "Permission denied" or "Read-only file system", check `ls -ld /scratch/users` (should be `drwxrwxrwt root root`) and the user's unit (`systemctl cat jupyter-<name>`).
- [ ] *(student)* A new home folder contains the `shared` link, and `~/shared/lab_data` is readable.
- [ ] Home quota: `zfs get defaultuserquota tank/home` shows 30G; *(student)* after first login, `zfs userspace tank/home` lists `jupyter-<name>` with a 30G quota, and writing past it fails: `head -c 31G /dev/urandom > ~/big` stops with "Disk quota exceeded" (random data, because lz4 compression would shrink a file of zeros to almost nothing; takes a few minutes). Delete `~/big` afterwards.

### Accounts, limits and groups

- [ ] Right after installing, `sudo tljh-config show` lists `auth: type: nativeauthenticator.NativeAuthenticator`, and the login page offers "Sign up" (not TLJH's "first use" login).
- [ ] Each admin whose password was set during setup logs in at `/hub/login` with it.
- [ ] Sign up a test student at `/hub/signup`, approve at `/hub/authorize`, log in.
- [ ] *(student)* `crontab -l` in a JupyterLab terminal says the user isn't allowed to use cron (if cron is installed: `which crontab`).
- [ ] *(student)* `systemctl show jupyter-<name> -p CPUQuotaPerSecUSec -p MemoryMax` shows `CPUQuotaPerSecUSec=4s` and `MemoryMax=8589934592` (8 GB); `echo $OMP_NUM_THREADS` in a terminal prints 4.
- [ ] Add the test user to `research` on the Admin page, restart their server: limits become 16 CPUs / 32 GB and `OMP_NUM_THREADS` 16.
- [ ] Idle shutdown stops an idle server after about an hour.
- [ ] A long job that prints nothing for over an hour (e.g. a `sleep`-based script in a notebook cell): note whether the idle shutdown kills it.

### GPU access

- [ ] *(student, not in `gpu`)* `ls /dev/nvidia*` finds nothing, and the JupyterLab terminal still works.
- [ ] Add the test user to `gpu`, restart their server: `nvidia-smi` works.

### Kernels, widgets and exports

- [ ] In "Python (PChem Lab)": nglview, py3Dmol and the IR widget all render.
- [ ] In "Python (CompChem)": `import matmalib` works (and `import gmxapi`, if GROMACS was built).
- [ ] *(student)* Export a notebook as PDF (LaTeX) and as WebPDF; tagged cells are left out.
- [ ] *(student)* The `pchem` templates appear in the Template launcher.

### Drop boxes

- [ ] `sudo tljh-make-dropbox <name>_<course>_<term> jupyter-<instructor>`; as a student, save a file into it; another student can see the name but not open it; the instructor can open it.

### Gaussian 16

- [ ] `tljh-install-gaussian` reports "Test passed" with E(RHF) matching Gaussian's reference (−74.9607232751), and on this AMD server reports `PGI_FASTMATH_CPU=haswell` (see docs/gaussian_setup_notes.md).
- [ ] *(student)* `echo $PGI_FASTMATH_CPU` in a JupyterLab terminal prints `haswell`.
- [ ] *(student)* A small job from a JupyterLab terminal (`g16 < input.com > output.log`) and from a notebook cell (`!g16 ...`) both end with "Normal termination", with the server's GPU and device access restricted (checks that shared memory still works).

### GROMACS

- [ ] `tljh-install-gromacs` completes, including `make check`. Confirmed Oct 2026: 2026.4 builds with CUDA 13.4 from NVIDIA's ubuntu2604 repository and passes all tests (with `iommu=pt`). Still to confirm: `import gmxapi` in the compchem kernel (a "GLIBCXX" error means the env needs `libstdcxx>=15`).
- [ ] `tljh-install-gromacs` prints "IOMMU check: 2 GPUs, peer-to-peer not blocked", and `make check` passes the multi-rank tests (`MdrunTestsTwoRanks`, `MdrunMpi2RankPmeTests`, `regressiontests/complex`); `sudo dmesg | grep -c IO_PAGE_FAULT` stays at 0.
- [ ] `gmx --version` as a test user shows `GPU support: CUDA`.
- [ ] *(gpu group)* A short GPU run with `gmx mdrun -ntmpi 1 -ntomp $OMP_NUM_THREADS` uses the GPU.
- [ ] Later, with real workloads: benchmark `GMX_SIMD=AVX_512` against `AVX2_256` (set in `config/gromacs_cache.cmake`).

### Network and access

- [ ] HTTPS through the DMZ proxy works from off campus (sections below).
- [ ] `chronyc sources -v` shows Reach above 0 (section 2).

## DMZ Reverse Proxy setup

ICIT has provisioned a VM running RedHat for us.

They request we do the following:

> Our gateway server in the DMZ will be handling the initial traffic requests and will be the initial HTTPS component of the routing. The gateway is built to communicate with other servers on the DMZ, so we'll be setting up a virtual server in the DMZ for you. That server will be managed by you and you'll need to install and configure a load balancer/rev. proxy (e.g. nginx/traefik/apache) to accept traffic from the gateway and proxy on to your lab system.
>
> The communication on the DMZ should be encrypted, so you'll need to generate a self-signed cert to install on whatever reverse proxy you intend to use. The communication between your DMZ virtual server and the lab machine should also be encrypted, so you'll need a self-signed cert or a Let's Encrypt cert on the lab machine and configure Traefik to use it.
>
> For the public address, we need a hostname to apply to this service (somehostname.hunter.cuny.edu) - do you have something in mind?
>
> Also, the communication between the DMZ virtual server and your lab machine is normally blocked and will need to be enabled. What we'll need to know is what port you need to connect to on the lab machine. If you configure Traefik with the SSL cert by following the TLJH guide, then that would be 443. But if you change it to something else, we'll need to know that. Just confirm when you have decided and the traffic can be enabled between the two systems.
>
> We'll let you know as soon as the virtual server is ready for you, along with the credentials to access it.
>
> Thank you,

The (seemingly) easiest guides use `nginx`. Using <https://www.redhat.com/sysadmin/setting-reverse-proxies-nginx> to get going.

- Installed nginx using `dnf install nginx`
- Start nginx at startup with `sudo systemctl enable --now nginx`
  - Able to check availability with `curl localhost`
- _May_ need to modify with SELinux permissions, as nginx only has access to ports 80 and 443 (HTTP, HTTPS)
  - SELinux blocks nginx from looking at cert file, blocks access to TCP socket 443

SElinux config script:

```bash
semanage import <<EOF
boolean -D
login -D
interface -D
user -D
port -D
node -D
fcontext -D
module -D
ibendport -D
ibpkey -D
permissive -D
boolean -m -1 httpd_can_network_connect
boolean -m -1 httpd_can_network_relay
boolean -m -1 httpd_graceful_shutdown
boolean -m -1 httpd_read_user_content
boolean -m -1 nis_enabled
boolean -m -1 virt_sandbox_use_all_caps
boolean -m -1 virt_use_nfs
EOF
```

Settings for nginx are located in `/etc/nginx/nginx.conf`.

Contents of `nginx.conf`

```nginx
error_log /var/log/nginx/error.log;
events { }
http {
        include         mime.types;
        include         /etc/nginx/proxy.conf;
        default_type    application/octet-stream;
        sendfile        on;
        keepalive_timeout       65;

log_format wscombined '$remote_addr - $remote_user [$time_local] '
                    '"$request" $status $body_bytes_sent '
                    'upgrade:"$http_upgrade" '
                    'connection:"$http_connection" '
                    'sent-connection:"$sent_http_connection" '
                    '"$http_referer" "$http_user_agent"';

        server {
                listen 443 ssl;
                ssl_certificate         /etc/pki/tls/certs/sugarcube.ss-crt.pem;
                ssl_certificate_key     /etc/pki/tls/private/sugarcube.ss-key.pem;

                ssl_verify_client       off;
                # ssl_trusted_certificate       /etc/pki/tls/certs/ca-bundle.crt;

                access_log /var/log/nginx/access_log wscombined;
                #access_log /var/log/nginx/access_log combined;

                location /{
                        proxy_pass https://<target-machine-ip>:443/;
                        proxy_set_header        Host                    "<target-host-name>.hunter.cuny.edu";
                        proxy_redirect          default;
                        proxy_http_version 1.1;
                        proxy_set_header Upgrade $http_upgrade;
                        proxy_set_header Connection "upgrade";
                        proxy_set_header X-Scheme "https";
                        proxy_set_header origin $http_origin;
                        proxy_set_header Sec-WebSocket-Key $http_sec_websocket_key;
                        proxy_set_header Sec-WebSocket-Version $http_sec_websocket_version;
                        proxy_buffering off;
                        } # end location
        } # end server
} # end http
```

Contents of `proxy.conf` (some settings overwritten by contents of `nginx.conf`)

```nginx
proxy_http_version 1.1;
proxy_set_header        Upgrade                 $http_upgrade;
proxy_set_header        Connection              "upgrade";
proxy_set_header        X-Real-IP               $remote_addr;
proxy_set_header        X-Forwarded-For         $proxy_add_x_forwarded_for;
proxy_set_header        X-Forwarded-User        $http_authorization;

#this is the maximum upload size
client_max_body_size       20m;
client_body_buffer_size    128k;

proxy_connect_timeout      90;
proxy_send_timeout         90;
proxy_read_timeout         90;
proxy_buffer_size          4k;
proxy_buffers              4 32k;
proxy_busy_buffers_size    64k;
proxy_temp_file_write_size 64k;
```

## JupyterHub TLS settings

With nginx configured on the DMZ machine, JupyterHub server will now receive traffic on port 443. To configure JupyterHub, perform the following:

- Generate a TLS key and certificate
  - `sudo openssl req -x509 -nodes -days 9999 -newkey rsa:2048 -keyout /etc/ssl/private/<key-name>.key -out /etc/ssl/certs/<cert-name>.crt`
- Enable https: `sudo tljh-config set https.enabled true`
- Set https port: `sudo tljh-config set https.port 443`
- Set key and certificate locations in TLJH
  - `sudo tljh-config set https.tls.key <key-location>`
  - `sudo tljh-config set https.tls.cert <cert-location>`

Check the following pages for info on setting up JupyterHub with a reverse proxy:

- <https://jupyterhub.readthedocs.io/en/stable/installation-guide-hard.html#setting-up-a-reverse-proxy>
- <https://jupyterhub.readthedocs.io/en/stable/reference/config-proxy.html>
- <https://github.com/jupyterhub/the-littlest-jupyterhub/issues/272>
- <https://flaviocopes.com/nginx-reverse-proxy/>
