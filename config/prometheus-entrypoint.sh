#!/bin/sh
set -eu

# Renders file_sd documents from environment variables so that no address is
# committed. Every scrape job that points at something outside this compose
# project goes through here; only same-project services (prometheus, loki,
# snmp-exporter) are named directly in prometheus.yml, because those names are
# defined in this repo and always exist.

SD_DIR=/tmp/prometheus-file-sd
mkdir -p "${SD_DIR}"

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

# emit_sd <out-file> <label-name> <default-port> [entry ...]
#
# Each entry is "target|label"; the label defaults to the target. A target
# without a port gets <default-port> appended, so a Netdata line can stay a
# bare address. Pass an empty default port for jobs whose target already
# carries one, or that are handed to an exporter as a parameter rather than
# scraped directly (FortiGate goes to snmp_exporter as ?target=).
#
# An empty entry list writes "[]", which Prometheus reads as "this job has no
# targets" rather than leaving a stale file behind.
emit_sd() {
  out="$1"
  label_name="$2"
  default_port="$3"
  shift 3

  {
    printf '[\n'
    comma=''
    for entry in "$@"; do
      target="${entry%%|*}"
      label="${entry#*|}"
      [ "${label}" = "${entry}" ] && label="${entry}"
      [ -z "${target}" ] && continue

      target="$(resolve_target "${target}")"
      [ -z "${target}" ] && continue

      case "${target}" in
        *:*) ;;
        *) [ -n "${default_port}" ] && target="${target}:${default_port}" ;;
      esac

      [ -n "${comma}" ] && printf '%b' "${comma}"
      cat <<EOF
  {
    "targets": ["${target}"],
    "labels": {"${label_name}": "${label}"}
  }
EOF
      comma=',\n'
    done
    printf ']\n'
  } > "${out}"
}

# Netdata targets come from every *_NETDATA_IP variable; the prefix becomes the
# node label, so adding a server is one line in .env and nothing else.
netdata_entries=''
for name in $(env | sed -n 's/^\([A-Za-z0-9_]*_NETDATA_IP\)=.*/\1/p' | sort); do
  eval "value=\${${name}:-}"
  [ -z "${value}" ] && continue
  netdata_entries="${netdata_entries} ${value}|${name%_NETDATA_IP}"
done

emit_sd "${SD_DIR}/netdata.json"      node    19999 ${netdata_entries}
emit_sd "${SD_DIR}/coder.json"        service ""    ${CODER_PROMETHEUS_TARGETS:-}
emit_sd "${SD_DIR}/fortigate.json"    device  ""    ${FORTIGATE_SNMP_TARGETS:-}
# Alloy lives in the syslog-docker project. Leaving this unset is the correct
# state for a deployment that does not run it - the job then has no targets
# instead of a permanently red one.
emit_sd "${SD_DIR}/syslog-alloy.json" service 12345 ${SYSLOG_ALLOY_TARGETS:-}

for f in netdata coder fortigate syslog-alloy; do
  printf 'prometheus-entrypoint: %s.json -> %s target(s)\n' \
    "${f}" "$(grep -c '"targets"' "${SD_DIR}/${f}.json" || true)" >&2
done

exec /bin/prometheus "$@"
