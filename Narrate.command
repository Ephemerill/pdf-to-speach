#!/bin/zsh
# Double-click to launch Narrate. First run creates a virtualenv and installs dependencies.
cd "$(dirname "$0")"
if [ ! -x .venv/bin/python ]; then
  echo "Setting up Narrate (one-time)…"
  python3 -m venv .venv && .venv/bin/pip install -q --upgrade pip && .venv/bin/pip install -q -r requirements.txt || { echo "Install failed"; read -k1; exit 1; }
fi
exec .venv/bin/python app.py 2> >(grep -v "Context leak detected" >&2)
