# demo_cockroachdb_molt_mysql
Demonstrate CockroachDB MOLT tools for low-downtime migration from MySQL to CockroachDB

This demo has the following features:
- Shallow learning curve.  You do not need to learn a lot just to get the demo to run.  All you need is Docker, and all you need to do is to run the demo script.
- Does not "pollute" your computer with installed applications etc.

Requires: Docker

This demo performs the following steps:
- Start MySQL
- Populate MySQL with sample data
- Configure GTID-based replication for MySQL
- Start a 3-node CockroachDB cluster with HAProxy load balancer
- Use MOLT Fetch to bulk-copy the data from MySQL to CockroachDB
- Use MOLT Verify to compare MySQL source data to CockroachDB target data
- Set up streaming replication using MOLT Replicator
- Demonstrate replication
- Set up streaming replication in the reverse direction using MOLT Replicator to support low-downtime migration failback if necessary
- Demonstrate reverse replication
- Shut down reverse migration
- Shut down MySQL
