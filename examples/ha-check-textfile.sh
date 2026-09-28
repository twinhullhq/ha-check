#!/usr/bin/env bash
# Writes ha-check results as Prometheus metrics for node_exporter's textfile collector.
#   */1 * * * *  /usr/local/bin/ha-check-textfile.sh -c /etc/ha-check.conf
# node_exporter must run with --collector.textfile.directory=/var/lib/node_exporter
set -uo pipefail
DIR=${TEXTFILE_DIR:-/var/lib/node_exporter}
OUT="$DIR/ha_check.prom"
json=$(ha-check --json "$@")
{
  echo '# HELP ha_check_status Overall result: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN.'
  echo '# TYPE ha_check_status gauge'
  jq -r '"ha_check_status{cluster=\"\(.cluster)\"} \(.exit_code)"' <<<"$json"
  echo '# HELP ha_check_problems Number of WARN/CRIT findings per check.'
  echo '# TYPE ha_check_problems gauge'
  jq -r '.cluster as $c | [.results[] | select(.level=="WARN" or .level=="CRIT")] as $p
         | (["etcd","patroni","replication","routing","archiving","slots","backups"][]) as $k
         | "ha_check_problems{cluster=\"\($c)\",check=\"\($k)\"} \([$p[] | select(.check==$k)] | length)"' <<<"$json"
  echo '# HELP ha_check_last_run_timestamp_seconds When ha-check last ran.'
  echo '# TYPE ha_check_last_run_timestamp_seconds gauge'
  echo "ha_check_last_run_timestamp_seconds $(date +%s)"
} >"$OUT.$$" && mv "$OUT.$$" "$OUT"
