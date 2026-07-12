"""Repo-root conftest: puts the repo on sys.path so `pytest` resolves
`beehive` without an install, on any OS (python -m pytest already does this
via CWD; bare pytest does not)."""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
