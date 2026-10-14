# jupyter_config.py - notebook export settings for every user on the hub.
#
# Installed by scripts/tljh_server_setup.sh to
#   /opt/tljh/user/etc/jupyter/jupyter_config.py
# JupyterLab's "File > Save and Export Notebook As" menu and `jupyter
# nbconvert` in a terminal both read it. Keep the name: every Jupyter
# program reads jupyter_config.py, while jupyter_nbconvert_config.py would
# only reach the command line, not JupyterLab.
# Users get changes the next time their server starts.

c = get_config()  # noqa: F821

# --- Formats in the export menu ----------------------------------------------
# Shown: HTML, LaTeX, Markdown, Notebook, PDF (via LaTeX), Python, WebPDF
# (PDF via the HTML view, using a headless Chromium; no LaTeX needed).
c.LatexExporter.enabled = True
c.PDFExporter.enabled = True
c.WebPDFExporter.enabled = True
# Hidden:
c.ASCIIDocExporter.enabled = False
c.QtExporter.enabled = False
c.QtPDFExporter.enabled = False
c.QtPNGExporter.enabled = False
c.RSTExporter.enabled = False
c.ScriptExporter.enabled = False
c.SlidesExporter.enabled = False

# --- Leave tagged content out of exports ---------------------------------------
# Add a tag to a cell (Property Inspector, or View > Cell Toolbar in older
# interfaces). Applies to every export format.
c.TagRemovePreprocessor.enabled = True
c.TagRemovePreprocessor.remove_cell_tags = ["remove_cell", "hide_cell", "hide"]
c.TagRemovePreprocessor.remove_input_tags = ["remove_input", "hide_input"]
c.TagRemovePreprocessor.remove_all_outputs_tags = ["remove_output", "hide_output"]

# LaTeX/PDF exports: syntax-highlighting definitions for code cells.
c.LatexPreprocessor.enabled = True
