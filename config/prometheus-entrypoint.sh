#!/bin/sh
set -eu

# Append static host mappings when the IP is available.
if [ -n "${R7525_01_NETDATA_IP:-}" ]; then
  echo "${R7525_01_NETDATA_IP} r7525-01-netdata" >> /etc/hosts
fi

if [ -n "${RX2540M4_01_NETDATA_IP:-}" ]; then
  echo "${RX2540M4_01_NETDATA_IP} rx2540m4-01-netdata" >> /etc/hosts
fi

exec /bin/prometheus "$@"
