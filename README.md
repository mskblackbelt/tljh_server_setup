# Setup information for The Littlest JupyterHub (for Physical Chemistry)

This repository contains the setup scripts and files for creating a bare metal installation of [The Littlest JupyterHub](https://tljh.jupyter.org/) along with templates and Conda environments designed for use in the physical chemistry lab at Hunter College. The lab guides for that course [are also available](https://github.com/mskblackbelt/Chem357).

The server serves undergraduate lab courses (PChem, CompChem) and light research work, with per-user limits, course kernels, Gaussian 16, GROMACS (GPU), and uv and ty (ty as the JupyterLab language server).

## Documentation

See the [`docs`](docs/) folder:

- [`docs/server_setup.md`](docs/server_setup.md): building the server, from the base system (Ubuntu, time sync, ZFS storage) through running the setup script, what gets installed where, users, limits and hub groups, software, the **Testing** checklist, and the DMZ reverse proxy and HTTPS.
- [`docs/gaussian_setup_notes.md`](docs/gaussian_setup_notes.md): how Gaussian 16 is installed and why.

## Quick start

On a prepared server (sections 1–3 of `docs/server_setup.md`), from your own admin account:

```bash
bash scripts/tljh_server_setup.sh
```

## Repository layout

| Folder | Contents |
| --- | --- |
| `scripts/` | `tljh_server_setup.sh` and the admin commands it installs (`tljh-install-kernel`, `tljh-make-dropbox`, `tljh-install-gaussian`, `tljh-install-gromacs`, `tljh-install-uv-ty`) |
| `config/` | Jupyter export settings (`jupyter_config.py`), hub settings (`jupyterhub_config.d/`), GROMACS build settings |
| `environments/` | Packages for the JupyterLab environment (`base_requirements.txt`) and the course kernels (`*_env.yaml`) |
| `templates/` | Notebook and LaTeX report templates, one folder per course |
| `docs/` | Documentation (above) |
| `sample_reports/` | Example student reports |
