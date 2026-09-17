#!/usr/bin/env bash
# Validate rendered HAProxy and nginx configuration templates.
#
# Runs every check inside images that are already in the registry, because the
# CI runner this was built for has no route to the internet — only to the
# internal registry. That constraint is worth keeping even when you do have
# internet: a validation job that installs packages is a validation job that
# breaks when a mirror is down.
#
# Usage:
#   scripts/validate.sh                 # validate everything
#   scripts/validate.sh haproxy         # one family
#   REGISTRY=registry.example.com scripts/validate.sh
set -euo pipefail

cd "$(dirname "$0")/.."

REGISTRY="${REGISTRY:-}"
HAPROXY_IMAGE="${HAPROXY_IMAGE:-${REGISTRY:+$REGISTRY/}haproxy:2.9-alpine}"
NGINX_IMAGE="${NGINX_IMAGE:-${REGISTRY:+$REGISTRY/}nginx:1.27-alpine}"

failed=0

# GitHub Actions turns these into annotations on the file itself; outside CI
# they are just readable error lines.
err() {
  local file="$1" msg="$2"
  echo "::error file=${file}::${msg}"
  echo "  FAIL ${file}: ${msg}" >&2
  failed=1
}

ok() { echo "  ok   $1"; }

# envsubst with no argument substitutes EVERY $NAME it finds — which quietly
# destroys nginx configs, where $host, $remote_addr and $uri are nginx's own
# variables and must survive into the rendered file. Passing an explicit list
# of names is the difference between a working config and a 404 that takes an
# afternoon to explain. The list is derived from the vars file, so adding a
# variable to the environment is enough; nobody has to remember this script.
subst_list() {
  local vars_file="$1"; shift
  local names=("$@")
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    names+=("${line%%=*}")
  done < "$vars_file"
  printf '${%s} ' "${names[@]}"
}

# envsubst leaves anything it could not substitute as a literal ${NAME}.
# That is the single most common production incident with templated configs:
# the config is syntactically valid and semantically wrong. Catch it first.
check_unsubstituted() {
  local rendered="$1" source="$2"
  if grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$rendered"; then
    local names
    names=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$rendered" | sort -u | tr '\n' ' ')
    err "$source" "unsubstituted variables: ${names}"
    return 1
  fi
  return 0
}

validate_haproxy() {
  echo "HAProxy templates"
  shopt -s nullglob
  local found=0
  for t in templates/haproxy/*.cfg.template; do
    found=1
    local rendered
    rendered=$(mktemp)
    # shellcheck disable=SC2046
    set -a; . ./templates/haproxy/vars.env; set +a
    envsubst "$(subst_list ./templates/haproxy/vars.env)" < "$t" > "$rendered"

    # Piped in rather than bind-mounted: the haproxy image runs as a non-root
    # user and mktemp produces a 0600 file owned by the caller, so a mount
    # fails with "Permission denied" on Linux while passing on Docker Desktop,
    # which rewrites ownership. stdin sidesteps ownership entirely.
    if check_unsubstituted "$rendered" "$t"; then
      if docker run --rm -i "$HAPROXY_IMAGE" haproxy -c -f /dev/stdin \
           < "$rendered" >/dev/null 2>&1; then
        ok "$t"
      else
        local out
        # `|| true` matters: under `set -e` with pipefail a failing command
        # substitution aborts the script here, so the validator would exit 1
        # without ever printing which template broke or why — which is most of
        # its value.
        out=$(docker run --rm -i "$HAPROXY_IMAGE" haproxy -c -f /dev/stdin \
              < "$rendered" 2>&1 | tail -3 | tr '\n' ' ' || true)
        err "$t" "haproxy -c: ${out}"
      fi
    fi
    rm -f "$rendered"
  done
  [ "$found" = 1 ] || echo "  (no templates)"
}

validate_nginx() {
  echo "nginx templates"
  shopt -s nullglob
  local found=0
  local workdir
  workdir=$(mktemp -d)

  # nginx -t parses the whole configuration, so the server blocks need a
  # wrapping http{} context and certificates that exist. Self-signed ones
  # generated per run are fine — we are checking syntax, not trust.
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$workdir/key.pem" \
    -out "$workdir/cert.pem" -days 1 -subj "/CN=ci.invalid" >/dev/null 2>&1

  # nginx -t needs these on disk because of the include, and the container may
  # not run as root. mktemp -d is 0700 and its files 0600, which the container
  # user cannot read on Linux.
  chmod 755 "$workdir"

  for t in templates/nginx/*.conf.template; do
    found=1
    set -a; . ./templates/nginx/vars.env; set +a
    export TLS_CERT=/etc/ci/cert.pem TLS_KEY=/etc/ci/key.pem
    envsubst "$(subst_list ./templates/nginx/vars.env TLS_CERT TLS_KEY)" \
      < "$t" > "$workdir/site.conf"

    if check_unsubstituted "$workdir/site.conf" "$t"; then
      cat > "$workdir/nginx.conf" <<'CONF'
events {}
http {
    include /etc/ci/site.conf;
}
CONF
      chmod 644 "$workdir"/*.pem "$workdir/site.conf" "$workdir/nginx.conf"
      if docker run --rm \
           -v "$workdir/nginx.conf:/etc/nginx/nginx.conf:ro" \
           -v "$workdir:/etc/ci:ro" \
           "$NGINX_IMAGE" nginx -t >/dev/null 2>&1; then
        ok "$t"
      else
        local out
        out=$(docker run --rm \
              -v "$workdir/nginx.conf:/etc/nginx/nginx.conf:ro" \
              -v "$workdir:/etc/ci:ro" \
              "$NGINX_IMAGE" nginx -t 2>&1 | tail -3 | tr '\n' ' ' || true)
        err "$t" "nginx -t: ${out}"
      fi
    fi
  done
  rm -rf "$workdir"
  [ "$found" = 1 ] || echo "  (no templates)"
}

case "${1:-all}" in
  haproxy) validate_haproxy ;;
  nginx)   validate_nginx ;;
  all)     validate_haproxy; validate_nginx ;;
  *) echo "usage: $0 [haproxy|nginx|all]" >&2; exit 2 ;;
esac

if [ "$failed" = 1 ]; then
  echo
  echo "Configuration validation failed." >&2
  exit 1
fi
echo
echo "All templates valid."
