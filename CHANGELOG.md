# Changelog

## 1.0.1 — 2026-09-29

- Security: Patroni basic-auth credentials are now passed to curl in a private temporary
  config file (removed on exit) instead of on curl's command line, where other local users
  could read them with `ps`. The README now recommends `PATRONI_AUTH=` in the config file
  over `--patroni-auth` on the command line for the same reason.

## 1.0.0 — 2026-09-28

First public release.

- Discovers all Patroni members from one REST API URL
- Checks: etcd quorum and raft-leader agreement; Patroni leader, member count, maintenance mode,
  pending restarts, DCS contact; replication state, lag, timelines, sync standby; RW/RO routing;
  WAL archiving; inactive replication slots; pgBackRest backup age
- Nagios-style exit codes, `--json`, `--quiet`, config file
- Never prompts for a password; reports login failures separately from outages
- `examples/ha-check-textfile.sh` for Prometheus (node_exporter textfile collector)
