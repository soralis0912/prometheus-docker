# prometheus-docker

Prometheus + Grafana + snmp_exporter, each fronted by its own Tailscale sidecar.

All targets come from `.env`; no host address appears in a committed file.

```
config/
  prometheus.yml                       scrape jobs
  prometheus-entrypoint.sh             renders file_sd JSON from .env at startup
  rules/server.yml                     node:*        recording rules (netdata)
  rules/fortigate.yml                  fortigate:*   recording rules (SNMP)
  rules/syslog.yml                     syslog:*      recording rules (log pipeline)
  snmp/snmp.yml                        snmp_exporter module for FortiOS
  loki/loki.yml                        log storage, retention via compactor
  grafana/provisioning/datasources/    Prometheus and Loki datasources
```

Dashboards are built once and kept out of git (see `.gitignore`); this repo
only defines the metrics they read.

## Adding targets

Everything is driven by environment variables read at container start, so
adding a device is an `.env` edit plus `docker compose up -d`.

| Variable | Purpose |
|---|---|
| `<NAME>_NETDATA_IP` | One per server. `<NAME>` becomes the `node` label. |
| `CODER_PROMETHEUS_TARGETS` | Space-separated `host:port\|label`. |
| `FORTIGATE_SNMP_TARGETS` | Space-separated `host\|label`. `label` becomes `device`. |
| `FORTIGATE_SNMP_COMMUNITY` | SNMPv2c community, expanded into `snmp.yml` at runtime. |

Servers are never named in the rules or dashboards - they aggregate
`by (node)`, so a new `*_NETDATA_IP` entry shows up everywhere on its own.

## FortiGate over SNMP

Metrics are pulled by `snmp-exporter` using a hand-written module built from
`FORTINET-FORTIGATE-MIB` plus the standard `IF-MIB`, so Fortinet's MIB archive
is not needed to rebuild `config/snmp/snmp.yml`. Verified against
FortiOS 8.0.

`config/snmp-entrypoint.sh` renders the community into the config at container
start. snmp_exporter's own `--config.expand-environment-variables` does not
cover the `community` field - it sends the literal `${...}` and the FortiGate
silently drops the request, which looks exactly like a wrong community.

Collected: CPU (total and per core), memory, disk, IPv4/IPv6 sessions and setup
rate, per-VDOM load, hardware sensors (temperature / fan / voltage / alarm),
per-interface counters and link state, IPsec tunnel state and throughput, and HA
member status.

### 1. Enable SNMP on the FortiGate

The exporter reaches the appliance from the Docker host, so the trusted host is
the **Docker host's LAN address**, not the container address.

```
config system snmp sysinfo
    set status enable
    set description "monitored by prometheus"
end

config system snmp community
    edit 1
        set name "<COMMUNITY>"
        set events cpu-high mem-low log-full intf-ip vpn-tun-up vpn-tun-down ha-switch ha-hb-failure
        config hosts
            edit 1
                set source-ip <DOCKER_HOST_IP>
                set ip <DOCKER_HOST_IP> 255.255.255.255
            next
        end
        set query-v2c-status enable
        set query-v2c-port 161
        set trap-v1-status disable
        set trap-v2c-status disable
    next
end
```

Then allow SNMP on the interface the host talks to:

```
config system interface
    edit "<INTERFACE>"
        append allowaccess snmp
    next
end
```

### 2. Point the stack at it

```
FORTIGATE_SNMP_TARGETS=<FORTIGATE_IP>|edge-firewall
FORTIGATE_SNMP_COMMUNITY=<COMMUNITY>
```

```
docker compose up -d snmp-exporter
docker compose up -d prometheus
```

### 3. Verify

Ask the exporter directly - this returns the raw SNMP walk and is the fastest
way to see whether the community and trusted host are right:

```
docker compose exec prometheus \
  wget -qO- 'http://snmp-exporter:9116/snmp?auth=fortigate_v2&module=fortigate&target=<FORTIGATE_IP>'
```

An empty response or `error: request timeout` means the FortiGate is not
answering: check the community string, the trusted host entry, and that
`snmp` is in `allowaccess` on the ingress interface.

Once data flows, confirm the job is up in Prometheus (`up{job="fortigate"}`)
and open **FortiGate / Overview** in Grafana.

### Sensors

`fgHwSensorEntValue` is an OCTET STRING holding the reading as text - `"10384"`
for a fan, `"51.25"` for a die temperature, but `"OK"` / `"ABSENT(0)"` for PSU
bays. No snmp_exporter type parses ASCII digits (`Float` silently returns 0 for
every sensor), so the module uses `regex_extracts` to pull the number out, and a
second extract exposes bay presence as `fgHwSensorEntValue_present` (1/0).

FortiOS prefixes the sensor name with its class - `TMP 1  CPUTIN`,
`FAN 2  SYS FAN`, `VOL 10 VBAT` - and the roll-ups in
`config/rules/fortigate.yml` match on that prefix. If a chart is empty, list the
real names and widen the pattern:

```
count by (fgHwSensorEntName) (fgHwSensorEntValue{job="fortigate"})
```

### Values that read zero legitimately

`fgSysDiskUsage` / `fgSysDiskCapacity` are 0 on units without a log disk (`get
system status` shows `Log hard disk: Not available`), and the `fortigate:vpn_*`
rules stay empty until an IPsec tunnel exists.

The same applies to IPMI on the servers: `config/rules/server.yml` matches a set
of known chassis-power and inlet-temperature sensor names across vendors rather
than a single machine's naming.

## Logs

Loki runs here and is published on `127.0.0.1:3100` only - never on the LAN.
Grafana reaches it as `loki:3100` on this compose network.

The receiving end lives in a separate project (`syslog-docker`) whose Alloy
joins this network, so it pushes to `loki:3100` and Prometheus scrapes it back
as `syslog-alloy:12345`. That scrape is what makes an ingest stall visible:
`syslog:lines_read_total_1h == 0` is a series with history, where an empty log
panel looks identical to a quiet device.

`config/rules/syslog.yml` rolls those up - lines read, entries sent, entries
**dropped** (the one loss mode an on-disk buffer cannot cover), and component
liveness.

## Dashboards

Not tracked here. Build them in Grafana against the recording rules above -
`node:*` for servers, `fortigate:*` for the firewall. If you do drop provisioned
JSON into `config/grafana/provisioning/dashboards/`, leave the panels' datasource
unset so they resolve Grafana's default (the provisioned Prometheus) instead of
pinning a UID that differs per install.

## Validating changes before deploying

```
docker run --rm -v "$PWD/config:/prom-config:ro" --entrypoint /bin/promtool \
  prom/prometheus:main check config /prom-config/prometheus.yml

docker run --rm -e FORTIGATE_SNMP_COMMUNITY=x \
  -v "$PWD/config/snmp/snmp.yml:/snmp-config/snmp.yml:ro" \
  -v "$PWD/config/snmp-entrypoint.sh:/snmp-config/entrypoint.sh:ro" \
  --entrypoint /bin/sh prom/snmp-exporter:latest \
  /snmp-config/entrypoint.sh --dry-run
```
