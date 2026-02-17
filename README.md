# demo_cockroachdb_molt_mysql

Demonstrate CockroachDB MOLT tools for low-downtime migration from MySQL to CockroachDB.

## Features

- Shallow learning curve. You do not need to learn a lot just to get the demo to run.
- Does not "pollute" your computer with installed applications etc.

## Prerequisites

- Docker
- `jq` (used for JSON parsing and URL-encoding certificates)
- The following data files must be present in the working directory:
  - `MySQL_files/Chinook_MySql.sql` — MySQL Chinook sample database
  - `CockroachDB_files/Chinook_CockroachDB_from_MySql_NO_DATA_NO_CONSTRAINTS_NO_INDEXES.sql` — CockroachDB schema (no data, no constraints, no indexes)

## Quick Start

```bash
chmod +x demo_cockroachdb_molt_mysql.sh
./demo_cockroachdb_molt_mysql.sh
```

The script pauses between steps so you can inspect output. Press Enter to continue.

### Flags

| Flag              | Description                           |
|-------------------|---------------------------------------|
| `--nopause`, `-n` | Skip interactive pauses between steps |
| `--reset`, `-r`   | Tear down all containers, networks, and generated files |

### Reset the environment

```bash
./demo_cockroachdb_molt_mysql.sh --reset
```

This removes all Docker containers, networks, certificate directories, data directories, and output files created by the script.

## What the demo does

1. Start MySQL and populate with the Chinook sample database
2. Configure GTID-based replication for MySQL
3. Start a 3-node CockroachDB cluster with HAProxy load balancer
4. Use MOLT Fetch to bulk-copy data from MySQL to CockroachDB
5. Use MOLT Verify to compare MySQL source data to CockroachDB target data
6. Set up streaming replication using MOLT Replicator
7. Demonstrate replication by inserting new data
8. Set up reverse replication (failback) using MOLT Replicator and CockroachDB changefeeds
9. Demonstrate reverse replication
10. Decommission: shut down reverse migration and MySQL

## Notes

- All credentials and TLS-disable flags are for local demo purposes only. Use proper secrets management and TLS in production.
- The script uses a custom Docker bridge network (`us-west2-net`, subnet `172.27.0.0/16`) with fixed container IPs.
- MOLT requires GTID-based replication to be enabled on MySQL.
