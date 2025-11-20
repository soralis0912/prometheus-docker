#!/bin/sh
set -eu

# Build file-based service discovery targets based on provided IPs.
SD_DIR=/tmp/prometheus-file-sd
SD_FILE="${SD_DIR}/netdata.json"
mkdir -p "${SD_DIR}"

{
  printf '[\n'
  sep=''

  if [ -n "${R7525_01_NETDATA_IP:-}" ]; then
    printf '  %s{\n    "targets": ["%s:19999"],\n    "labels": {"node": "R7525_01"}\n  }\n' "$sep" "${R7525_01_NETDATA_IP}"
    sep=','
  fi

  if [ -n "${RX2540M4_01_NETDATA_IP:-}" ]; then
    printf '  %s{\n    "targets": ["%s:19999"],\n    "labels": {"node": "RX2540M4_01"}\n  }\n' "$sep" "${RX2540M4_01_NETDATA_IP}"
    sep=','
  fi

  printf ']\n'
} > "${SD_FILE}"

exec /bin/prometheus "$@"
