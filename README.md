# ha-check

**Is your Patroni cluster really healthy? One command, one answer.**

`patronictl list` tells you who the leader is. It doesn't tell you that etcd is one failure
away from losing quorum, that WAL archiving has been failing since Tuesday, that your HAProxy
read-write port is sending writes to a replica, or that nobody has taken a backup in three days.
`ha-check` does, in about a second, with exit codes your monitoring already understands.

```
$ ha-check -c /etc/ha-check.conf
ha-check 1.0.0  cluster=main  2026-09-28T15:01:25+03:00

etcd
  OK    etcd         http://10.0.0.11:2379 healthy
  OK    etcd         http://10.0.0.12:2379 healthy
  OK    etcd         http://10.0.0.13:2379 healthy

patroni
  OK    patroni      leader is pg3 (timeline 6)
  OK    patroni      3/3 members registered

replication
  OK    replication  pg1 (replica) streaming, lag 0B
  OK    replication  pg2 (replica) streaming, lag 0B

routing & durability
  OK    routing      RW 10.0.0.10:5000 → primary
  OK    routing      RO 10.0.0.10:5001 → replica
  OK    archiving    last WAL archived 78s ago
  OK    slots        no inactive replication slots

backups
  OK    backups      newest backup: full, 9h ago

Overall: OK
```

And on a bad day:

```
$ ha-check -c /etc/ha-check.conf --quiet
  WARN  etcd         http://10.0.0.13:2379 unhealthy or unreachable
  WARN  etcd         2/3 healthy: quorum held, but one more failure stops failover
  CRIT  patroni      only 2 of 3 members registered in the DCS

Overall: CRITICAL
```

## What it checks

| Area | Checks |
|---|---|
| **etcd** | every member healthy; quorum present (CRITICAL when lost, WARNING when one more failure would lose it); all members agree on the raft leader |
| **Patroni** | exactly one leader (none or two is CRITICAL); expected number of members registered; maintenance mode (paused); pending restarts; each member's REST API reachable; each member recently in contact with the DCS; `failsafe_mode` off (info) |
| **Replication** | every replica `streaming`; lag against warning/critical thresholds; replicas on the leader's timeline; a sync standby exists when `synchronous_mode` is on; at least one streaming replica |
| **Routing** | your read-write endpoint lands on the primary; your read-only endpoint lands on a replica (HAProxy, VIP, PgBouncer, anything that speaks the PostgreSQL protocol) |
| **Archiving** | `archive_mode` on; WAL archiving not failing; time since the last archived WAL |
| **Slots** | inactive replication slots and how much WAL each one is holding back |
| **Backups** | age of the newest pgBackRest backup |

Only the Patroni checks are mandatory. Everything else switches on when you give it what it needs
(`--etcd`, `--rw`/`--ro`, `--stanza`), and says so when it's skipped.

## Install

```bash
sudo curl -fsSL -o /usr/local/bin/ha-check https://raw.githubusercontent.com/twinhullhq/ha-check/main/ha-check
sudo chmod +x /usr/local/bin/ha-check
ha-check --version
```

Needs `bash` 4+, `curl` and `jq`. `psql` enables the routing, archiving and slot checks;
`pgbackrest` on the same host enables the backup check. One file, no daemon, nothing to compile.
Run it from any machine that can reach the cluster: a node, a bastion, or your monitoring server.

## Use

```bash
# the minimum: any one Patroni REST API; the other members are discovered from it
ha-check --patroni http://10.0.0.11:8008

# everything
ha-check --patroni http://10.0.0.11:8008 --expect-members 3 \
         --etcd http://10.0.0.11:2379,http://10.0.0.12:2379,http://10.0.0.13:2379 \
         --rw 10.0.0.10:5000 --ro 10.0.0.10:5001 --pg-user monitor \
         --stanza main
```

Always pass `--expect-members`. When a node dies, Patroni removes it from the DCS after `ttl`
seconds; without the expected count, a cluster that quietly shrank from three members to two
looks healthy.

### Config file

Easier for cron and monitoring agents. Keys are the long option names in upper case:

```ini
# /etc/ha-check.conf
PATRONI=http://10.0.0.11:8008, http://10.0.0.12:8008
EXPECT_MEMBERS=3
ETCD=http://10.0.0.11:2379,http://10.0.0.12:2379,http://10.0.0.13:2379
RW=10.0.0.10:5000
RO=10.0.0.10:5001
PG_USER=monitor
STANZA=main
LAG_WARN=1048576
LAG_CRIT=104857600
BACKUP_MAX_AGE=26
```

Give several `PATRONI` URLs: if the first member is down, the next one answers.

### All options

| Option | Default | |
|---|---|---|
| `--patroni URL` | *required* | Patroni REST API of any member (repeatable or comma-separated) |
| `--expect-members N` | as registered | members the cluster should have |
| `--etcd URLS` | skipped | etcd client URLs, comma-separated |
| `--etcd-cacert` `--etcd-cert` `--etcd-key` | | etcd mutual TLS |
| `--patroni-cacert FILE` | | CA for a Patroni REST API on https |
| `--patroni-auth USER:PASS` | | basic auth for the Patroni REST API. Prefer `PATRONI_AUTH=` in the config file: command-line arguments are visible in `ps` |
| `--insecure` | | skip TLS verification (not recommended) |
| `--rw HOST:PORT` / `--ro HOST:PORT` | skipped | endpoints your applications use |
| `--pg-user USER` | `$PGUSER` or `postgres` | user for the SQL checks |
| `--stanza NAME` | skipped | pgBackRest stanza |
| `--pgbackrest-config FILE` | pgBackRest default | |
| `--lag-warn BYTES` / `--lag-crit BYTES` | 1 MB / 100 MB | replica lag thresholds |
| `--backup-max-age HOURS` | 26 | daily backups plus 2 hours of slack |
| `-c, --config FILE` | | settings file (above) |
| `--json` | | machine-readable report |
| `-q, --quiet` | | only problems and the verdict |
| `--no-color` | colour on a terminal | |

## A read-only monitoring user

Don't monitor as a superuser. The built-in `pg_monitor` role is enough for every SQL check:

```sql
CREATE ROLE monitor LOGIN PASSWORD 'change-me' IN ROLE pg_monitor;
```

Allow it in `pg_hba.conf` (Patroni: `postgresql.pg_hba` in the DCS config), then give the
password to `ha-check` through `~/.pgpass` of the user that runs it, never on the command line:

```
10.0.0.10:*:postgres:monitor:change-me
10.0.0.11:*:postgres:monitor:change-me
```

`ha-check` never prompts: if the password is missing it reports "login failed" instead of hanging your cron job.

## Exit codes and integrations

`0` OK · `1` WARNING · `2` CRITICAL · `3` UNKNOWN (bad arguments, missing `curl`/`jq`). That's the
Nagios plugin convention, also used by Icinga, Zabbix, Sensu, Checkmk and most others.

**Nagios / Icinga**

```
define command {
  command_name  check_patroni_cluster
  command_line  /usr/local/bin/ha-check -c /etc/ha-check.conf --quiet --no-color
}
```

**Zabbix** (agent `UserParameter`, then a trigger on `last()>0`)

```
UserParameter=patroni.hacheck,/usr/local/bin/ha-check -c /etc/ha-check.conf -q --no-color >/dev/null; echo $?
```

**Cron and e-mail** (the minimum that still beats nothing)

```
*/5 * * * *  ha-check -c /etc/ha-check.conf -q --no-color || ha-check -c /etc/ha-check.conf --no-color | mail -s "cluster NOT OK" dba@example.com
```

**Prometheus** via node_exporter's textfile collector: [`examples/ha-check-textfile.sh`](examples/ha-check-textfile.sh)
writes `ha_check_status` and a per-check `ha_check_problems` gauge. Alert on `ha_check_status > 0`
and on `time() - ha_check_last_run_timestamp_seconds > 300`.

**JSON** for anything else:

```bash
ha-check -c /etc/ha-check.conf --json | jq '.status, [.results[] | select(.level != "OK")]'
```

## Tested

Version 1.0.0 was run against a live three-node cluster (PostgreSQL 16, Patroni 4.1.5,
etcd 3.6.15, HAProxy 2.8, pgBackRest 2.50 on Ubuntu 24.04) in these states: healthy; a replica
crashed (REST API unreachable, then dropped out of the DCS); cluster paused; an etcd member frozen;
Patroni API unreachable; wrong and missing database credentials; endpoint down. `shellcheck` clean.

It reads Patroni's standard REST API (`/cluster`, `/config`, `/patroni`), so it should work with
Patroni 2.1 and later and any DCS; the etcd section is etcd-specific. If something reports wrong
on your setup, [open an issue](https://github.com/twinhullhq/ha-check/issues) with the `--json` output.

## Want the whole cluster, not just the check?

`ha-check` comes from the **[Twinhull HA Kit for PostgreSQL](https://twinhullhq.com)**: production
templates for Patroni, etcd, HAProxy, keepalived and pgBackRest generated from one file, a
failover drill that measures downtime and data loss, a disaster-recovery runbook, a 3-node lab,
and a 38-page guide. Every procedure in it was run on a real cluster before it was written down.

## License

MIT. See [LICENSE](LICENSE).
