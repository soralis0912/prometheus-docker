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

# Build file-based service discovery targets based on provided IPs.
SD_DIR=/tmp/prometheus-file-sd
SD_FILE="${SD_DIR}/netdata.json"
mkdir -p "${SD_DIR}"

{
  printf '[\n'
  JSON_COMMA=''
  add_target "${R7525_01_NETDATA_IP:-}" "R7525_01"
  add_target "${RX2540M4_01_NETDATA_IP:-}" "RX2540M4_01"
  printf ']\n'
} > "${SD_FILE}"

exec /bin/prometheus "$@"
