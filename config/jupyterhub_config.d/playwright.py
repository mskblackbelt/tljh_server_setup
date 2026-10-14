# playwright.py - where users' servers find the shared headless Chromium
# used for WebPDF export (installed by scripts/tljh_server_setup.sh, step 8).
#
# Installed by tljh_server_setup.sh (step 7) into
#   /opt/tljh/config/jupyterhub_config.d/

c = get_config()  # noqa: F821

c.Spawner.environment.update({"PLAYWRIGHT_BROWSERS_PATH": "/opt/tljh/playwright"})
