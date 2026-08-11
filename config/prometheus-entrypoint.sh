#!/bin/sh
set -eu

# Resolve host-gateway placeholder to the Docker gateway address.
resolve_target() {
  value="$1"

  case "${value}" in
    host-gateway|host.docker.internal)
      if [ -z "${HOST_GATEWAY_IP:-}" ]; then
        HOST_GATEWAY_IP="$(ip -4 route show default | awk 'NR==1 {print $3}')"
      fi
      printf '%s' "${HOST_GATEWAY_IP}"
      ;;
    *)
      printf '%s' "${value}"
      ;;
  esac
}

add_target() {
  ip="$1"
  label="$2"

  if [ -z "${ip}" ]; then
    return
  fi

  resolved_ip="$(resolve_target "${ip}")"

  if [ -z "${resolved_ip}" ]; then
    return
  fi

  if [ -n "${JSON_COMMA:-}" ]; then
    printf '%b' "${JSON_COMMA}"
  fi

  cat <<EOF
  {
    "targets": ["${resolved_ip}:19999"],
    "labels": {"node": "${label}"}
  }
EOF

  JSON_COMMA=',\n'
}

add_coder_target() {
  target="$1"
  label="$2"

  if [ -z "${target}" ]; then
    return
  fi

  resolved_target="$(resolve_target "${target}")"

  if [ -z "${resolved_target}" ]; then
    return
  fi

  if [ -n "${CODER_JSON_COMMA:-}" ]; then
    printf '%b' "${CODER_JSON_COMMA}"
  fi

  cat <<EOF
  {
    "targets": ["${resolved_target}"],
    "labels": {"service": "${label}"}
  }
EOF

  CODER_JSON_COMMA=',\n'
}

add_fortigate_target() {
  target="$1"
  label="$2"

  if [ -z "${target}" ]; then
    return
  fi

  resolved_target="$(resolve_target "${target}")"

  if [ -z "${resolved_target}" ]; then
    return
  fi

  if [ -n "${FORTIGATE_JSON_COMMA:-}" ]; then
    printf '%b' "${FORTIGATE_JSON_COMMA}"
  fi

  # The address is handed to snmp_exporter as ?target=, not scraped directly.
  cat <<EOF
  {
    "targets": ["${resolved_target}"],
    "labels": {"device": "${label}"}
  }
EOF

  FORTIGATE_JSON_COMMA=',\n'
}

# Build file-based service discovery targets based on provided IPs.
SD_DIR=/tmp/prometheus-file-sd
SD_FILE="${SD_DIR}/netdata.json"
mkdir -p "${SD_DIR}"

{
  printf '[\n'
  JSON_COMMA=''
  # Auto-add every *_NETDATA_IP environment variable as a Netdata target.
  env | sort | while IFS='=' read -r name value; do
    case "${name}" in
      *_NETDATA_IP)
        label="${name%_NETDATA_IP}"
        add_target "${value}" "${label}"
        ;;
    esac
  done
  printf ']\n'
} > "${SD_FILE}"

# Build file-based service discovery targets for Coder metrics.
CODER_SD_FILE="${SD_DIR}/coder.json"
{
  printf '[\n'
  CODER_JSON_COMMA=''
  for entry in ${CODER_PROMETHEUS_TARGETS:-}; do
    # Allow "host:port|label" so multiple Coder instances can be distinguished.
    label="${entry#*|}"
    if [ "${label}" = "${entry}" ]; then
      label="${entry}"
    else
      entry="${entry%%|*}"
    fi

    add_coder_target "${entry}" "${label}"
  done
  printf ']\n'
} > "${CODER_SD_FILE}"

# Build file-based service discovery targets for FortiGate SNMP polling.
FORTIGATE_SD_FILE="${SD_DIR}/fortigate.json"
{
  printf '[\n'
  FORTIGATE_JSON_COMMA=''
  for entry in ${FORTIGATE_SNMP_TARGETS:-}; do
    # Allow "host|label" so multiple FortiGates can be distinguished.
    label="${entry#*|}"
    if [ "${label}" = "${entry}" ]; then
      label="${entry}"
    else
      entry="${entry%%|*}"
    fi

    add_fortigate_target "${entry}" "${label}"
  done
  printf ']\n'
} > "${FORTIGATE_SD_FILE}"

exec /bin/prometheus "$@"
