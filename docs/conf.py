# Sphinx configuration of the QSPI interface documentation.
# Build:  pip install -r docs/requirements.txt && sphinx-build -b html docs public

import subprocess
import sys
from pathlib import Path

project = "QSPI-Interface"
author = "Christopher Hinz, Hochschule München"
copyright = "2026, Hochschule München"
release = "1.0.0-beta.3"
version = release

language = "en"

extensions = [
    "myst_parser",
    "sphinxcontrib.wavedrom",
]

myst_enable_extensions = [
    "colon_fence",
    "deflist",
    "tasklist",
    "attrs_block",
]
myst_heading_anchors = 3

templates_path = ["_templates"]
# "generated" is pulled in via {include}, not as a standalone document
exclude_patterns = ["_build", "generated", "Thumbs.db", ".DS_Store"]

html_theme = "furo"
html_title = f"QSPI-Interface {release}"

# WaveDrom: render client-side in the HTML output (no node/wavedrom-cli
# needed; the JS is loaded from unpkg).
render_using_wavedrom_cli = False
wavedrom_html_jsinline = False


def _generate_register_map(app):
    """Generate the register map from docs/regs.yaml (single source of truth).

    Runs on every Sphinx build so that docs/generated/registers_gen.md is
    never edited by hand (and is not checked in at all). Also regenerates
    sw/include/qspi_regs.h, which IS checked in (CI verifies it is current).
    """
    here = Path(__file__).parent
    subprocess.run(
        [sys.executable, str(here / "gen_regmap.py")],
        check=True,
        cwd=here,
    )


def setup(app):
    app.connect("builder-inited", _generate_register_map)
