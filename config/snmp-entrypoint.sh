#!/bin/sh
set -eu

# Render config/snmp/snmp.yml into a runtime copy with credentials substituted
# from the environment, then start snmp_exporter.
#
# snmp_exporter's --config.expand-environment-variables does not apply to the
# community field (verified against 0.30.1: the literal "${...}" is sent as the
# community and the device silently drops the request, which looks exactly like
# a wrong community), so the substitution happens here.
#
# Every ${NAME} in the template is replaced with that environment variable.
# awk does the substring surgery rather than sed doing a regex replace, so a
# credential containing /, & or \ is not mangled, and substituted text is never
# rescanned.

TEMPLATE=/snmp-config/snmp.yml
RENDERED_DIR=/tmp/snmp
RENDERED="${RENDERED_DIR}/snmp.yml"

# The rendered file holds credentials - keep it readable only by this user.
umask 077
mkdir -p "${RENDERED_DIR}"

for name in $(sed -n 's/.*\${\([A-Za-z_][A-Za-z0-9_]*\)}.*/\1/p' "${TEMPLATE}" | sort -u); do
  eval "value=\${${name}:-}"
  if [ -z "${value}" ]; then
    echo "snmp-entrypoint: ${name} is empty; targets using it will time out" >&2
  fi
done

awk '
{
  out = ""
  rest = $0
  while (match(rest, /\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
    name = substr(rest, RSTART + 2, RLENGTH - 3)
    out = out substr(rest, 1, RSTART - 1) ENVIRON[name]
    rest = substr(rest, RSTART + RLENGTH)
  }
  print out rest
}' "${TEMPLATE}" > "${RENDERED}"

exec /bin/snmp_exporter --config.file="${RENDERED}" "$@"
