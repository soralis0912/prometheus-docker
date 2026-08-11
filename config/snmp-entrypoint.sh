#!/bin/sh
set -eu

# Render config/snmp/snmp.yml into a runtime copy with the SNMP credentials
# substituted from the environment, then start snmp_exporter on it.
#
# snmp_exporter's --config.expand-environment-variables does not apply to the
# community field, so the substitution is done here. Doing it with shell
# parameter expansion rather than sed keeps credentials containing /, & or \
# from being mangled.

TEMPLATE=/snmp-config/snmp.yml
RENDERED_DIR=/tmp/snmp
RENDERED="${RENDERED_DIR}/snmp.yml"
PLACEHOLDER='${FORTIGATE_SNMP_COMMUNITY}'

if [ -z "${FORTIGATE_SNMP_COMMUNITY:-}" ]; then
  echo "snmp-entrypoint: FORTIGATE_SNMP_COMMUNITY is empty; FortiGate scrapes will time out" >&2
fi

# The rendered file holds a credential - keep it readable only by this user.
umask 077
mkdir -p "${RENDERED_DIR}"

while IFS= read -r line; do
  case "${line}" in
    *"${PLACEHOLDER}"*)
      prefix="${line%%"${PLACEHOLDER}"*}"
      suffix="${line#*"${PLACEHOLDER}"}"
      printf '%s%s%s\n' "${prefix}" "${FORTIGATE_SNMP_COMMUNITY:-}" "${suffix}"
      ;;
    *)
      printf '%s\n' "${line}"
      ;;
  esac
done < "${TEMPLATE}" > "${RENDERED}"

exec /bin/snmp_exporter --config.file="${RENDERED}" "$@"
