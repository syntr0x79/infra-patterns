#!/usr/bin/env bash
# Render haproxy.cfg.j2 with the example vars and check it with haproxy -c.
# Same idea as ../ci-config-validation: a template that has never been
# rendered has never been tested.
set -euo pipefail
cd "$(dirname "$0")"

PY="${PYTHON:-python3}"
if ! "$PY" -c 'import jinja2, yaml' 2>/dev/null; then
  echo "need python with jinja2 and pyyaml; set PYTHON=/path/to/python" >&2
  echo "(any ansible installation has both)" >&2
  exit 2
fi

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT

"$PY" - "$rendered" <<'PY'
import pathlib, sys, jinja2, yaml
out = pathlib.Path(sys.argv[1])
v = yaml.safe_load(pathlib.Path("haproxy/vars.example.yml").read_text())
t = jinja2.Template(pathlib.Path("haproxy/haproxy.cfg.j2").read_text(),
                    trim_blocks=True, keep_trailing_newline=True)
out.write_text(t.render(**v))
PY

docker run --rm -v "$rendered:/tmp/h.cfg:ro" haproxy:2.9-alpine haproxy -c -f /tmp/h.cfg
echo "haproxy.cfg.j2 renders to a valid configuration"
