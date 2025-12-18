#!/bin/bash

# Set options for better shell script behavior
# Per https://gist.github.com/mohanpedala/1e2ff5661761d3abd0385e8223e16425
#
# The set -e option instructs bash to immediately exit 
# if any command has a non-zero exit status.
#
# When -u is set, a reference to any variable you haven't previously 
# defined - with the exceptions of $* and $@ - is an error, and causes 
# the program to immediately exit.
#
# The -o pipefail setting prevents errors in a pipeline from being masked. 
# If any command in a pipeline fails, that return code will be used as 
# the return code of the whole pipeline. 
set -euo pipefail

# Uncomment to turn on shell tracing
# set -x

# Docker container versions (can specify "latest" too)
MYSQL_VERSION='8.4.6'
COCKROACHDB_VERSION='v25.2.8'
HAPROXY_VERSION='1.7'

MYSQL_ROOT_PASSWORD='root_root_root'
MYSQL_STARTUP_SLEEP=20
REVERSE_REPLICATION_LATENCY_SLEEP=10
NUM_NEW_ARTISTS_MYSQL=50
NUM_NEW_ARTISTS_MYSQL2=10
NUM_NEW_ALBUMS_MYSQL=50

# Script pause until user presses Enter key
pause() {
  echo ""
  read -p "⏸️  Press [Enter] to continue to the next step..." _
  echo ""
}

echo 'Next step: Create the region network for Docker containers to use'
pause

echo 'Creating the region network'
docker network create --driver=bridge --subnet=172.27.0.0/16 --ip-range=172.27.0.0/24 --gateway=172.27.0.1 us-west2-net

echo
echo 'Setting up MySQL...'
echo
echo 'Start MySQL'
pause

# Start MySQL
# Ref: https://hub.docker.com/_/mysql

docker run \
 -d \
 --name my-mysql-db \
 --hostname=mysql_host \
 --ip=172.27.0.101 \
 --net=us-west2-net \
 -e MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD \
 -p 3306:3306 \
 -v $PWD/mysql_files:/mysql_files:ro \
 mysql:$MYSQL_VERSION

echo
echo "Sleeping $MYSQL_STARTUP_SLEEP seconds..."
echo '(imagine seeing dumb jokes being displayed every few seconds to pass the time)'
echo
echo 'MySQL needs to be given time to become ready for connections.'
echo 'This is different from CockroachDB, which does not return control after being'
echo 'started until it is ready to accept connections.'
echo
echo 'This initial wait happens in 2 steps:'
echo "1. Sleep unconditionally for a while (in this case $MYSQL_STARTUP_SLEEP seconds)."
echo '2. Additionally, wait for an admin MySQL ping command to return (it will block until MySQL is ready).'
sleep $MYSQL_STARTUP_SLEEP

echo
echo "MySQL has started.  Waiting for it to start accepting connections..."
docker exec -it my-mysql-db mysqladmin ping -h localhost -u root --password=$MYSQL_ROOT_PASSWORD --wait=30

echo
echo 'Initial set of databases:'
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SHOW DATABASES'

echo
echo 'Create database schema and populate with initial data'
pause

docker exec -i my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD < MySQL_files/Chinook_MySql.sql

echo
echo 'List databases and tables in Chinook database'
pause

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SHOW DATABASES'
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e 'SHOW TABLES'

echo
echo 'Look at data samples'
pause

echo 'Album:'
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e 'SELECT * FROM Album ORDER BY AlbumID LIMIT 5'
echo
echo 'Artist:'
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e 'SELECT * FROM Artist ORDER BY ArtistID LIMIT 5'
echo
echo 'Customer:'
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e 'SELECT * FROM Customer ORDER BY CustomerID LIMIT 2\G'
echo
echo 'Employee:'
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e 'SELECT * FROM Employee ORDER BY EmployeeID LIMIT 2\G'
echo
echo 'Genre:'
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e 'SELECT * FROM Genre ORDER BY GenreID LIMIT 5'
echo
echo 'Invoice:'
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e 'SELECT * FROM Invoice ORDER BY InvoiceID LIMIT 5'
echo
echo 'InvoiceLine:'
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e 'SELECT * FROM InvoiceLine ORDER BY InvoiceLineID LIMIT 5'
echo
echo 'MediaType:'
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e 'SELECT * FROM MediaType ORDER BY MediaTypeID LIMIT 5'
echo
echo 'Playlist:'
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e 'SELECT * FROM Playlist ORDER BY PlaylistID LIMIT 5'
echo
echo 'PlaylistTrack:'
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e 'SELECT * FROM PlaylistTrack ORDER BY TrackID LIMIT 5'
echo
echo 'Track:'
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e 'SELECT * FROM Track ORDER BY TrackID LIMIT 3\G'

echo
echo 'Configure GTID-based replication...'
echo
echo 'Reference: https://dev.mysql.com/doc/refman/8.4/en/replication-mode-change-online-enable-gtids.html'
echo
echo 'Show the initial GTID settings'
pause
echo

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SHOW VARIABLES LIKE '\''%gtid%'\'
echo

echo 'Next step: set enforce_gtid_consistency to WARN'
pause
echo

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SET @@GLOBAL.enforce_gtid_consistency = WARN'
echo
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SHOW VARIABLES LIKE '\''%gtid%'\'
echo

echo 'Next step: set enforce_gtid_consistency to ON'
pause
echo

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SET @@GLOBAL.enforce_gtid_consistency = ON'
echo
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SHOW VARIABLES LIKE '\''%gtid%'\'
echo

echo 'Next step: set gtid_mode to OFF_PERMISSIVE'
pause
echo

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SET @@GLOBAL.gtid_mode = OFF_PERMISSIVE'
echo
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SHOW VARIABLES LIKE '\''%gtid%'\'
echo

echo 'Next step: set gtid_mode to ON_PERMISSIVE'
pause
echo

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SET @@GLOBAL.gtid_mode = ON_PERMISSIVE'
echo
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SHOW VARIABLES LIKE '\''%gtid%'\'
echo

echo 'Next step: set binlog_row_metadata to FULL'
pause
echo
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SET @@GLOBAL.BINLOG_ROW_METADATA = FULL'
echo
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SHOW VARIABLES LIKE '\''%binlog%'\'

echo 'Next step: Check for ongoing transactions'
pause
echo

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SHOW STATUS LIKE '\''Ongoing%'\'
echo

echo 'Next step: set gtid_mode to ON'
pause
echo

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SET @@GLOBAL.GTID_MODE = ON'
echo
docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SHOW VARIABLES LIKE '\''%gtid%'\'
echo

sleep 1

echo 'Generate some synthetic write traffic to get the first binary log to be flushed.'
echo 'At that point there will be a start and end to the GTID so GTID-based'
echo 'replication can start to be used.'
echo
echo 'Create a temporary database for the synthetic write traffic'
pause

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'CREATE DATABASE temp_delete'

echo
echo 'Create a table in the temporary database'
pause

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=temp_delete --table \
 -e 'CREATE TABLE t (pk SERIAL PRIMARY KEY, fname VARCHAR(100), lname VARCHAR(100), age integer)'

echo
echo 'Populate the table with some data'
pause

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=temp_delete --table -e \
"INSERT INTO t (fname, lname, age) 
  (WITH RECURSIVE NumberSeries AS (
    SELECT 1 AS n -- Anchor member: starting value
    UNION ALL
    SELECT n + 1 FROM NumberSeries WHERE n < 1000 -- Recursive member: increments and termination condition
  )
  SELECT concat('F', CAST((rand()*100.0) AS SIGNED)), concat('L', CAST((rand()*100.0) AS SIGNED)), CAST((rand()*100.0) AS SIGNED) 
  FROM NumberSeries)"

sleep 2

echo
echo 'Some rows just added:'

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=temp_delete --table -e "SELECT * FROM t LIMIT 10"

echo
echo 'Verify the first binary log has been flushed.'
echo 'This query should return a result.'
echo 'Even if it does not, proceed anyway - we will check this again later, right before we need it.'
pause

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SELECT @@global.gtid_executed'

# Set up CockroachDB
# Ref: https://www.cockroachlabs.com/blog/simulate-cockroachdb-cluster-localhost-docker/

echo
echo 'Setting up CockroachDB...'
echo

echo 'Next step: Create the haproxy.cfg file for HAProxy'
pause
echo 'Creating the haproxy.cfg file'

mkdir -p haproxy_data/us-west2
cat - >haproxy_data/us-west2/haproxy.cfg <<EOF

global
  maxconn 4096

defaults
    mode                tcp
    # Timeout values should be configured for your specific use.
    # See: https://cbonte.github.io/haproxy-dconv/1.8/configuration.html#4-timeout%20connect
    timeout connect     10s
    timeout client      1m
    timeout server      1m
    # TCP keep-alive on client side. Server already enables them.
    option              clitcpka

listen psql
    bind :26257
    mode tcp
    balance roundrobin
    option httpchk GET /health?ready=1
    server cockroach4 roach-seattle-1:26257 check port 8080
    server cockroach5 roach-seattle-2:26257 check port 8080
    server cockroach6 roach-seattle-3:26257 check port 8080

EOF

echo
echo 'Next step: Create the Docker containers for the 3 CockroachDB nodes'
pause
echo 'Creating the Docker container for CockroachDB 1 in Seattle'

# Create the Docker containers for the 3 CockroachDB nodes

docker run \
 -d \
 --name=roach-seattle-1 \
 --hostname=roach-seattle-1 \
 --ip=172.27.0.11 \
 --net=us-west2-net \
 --add-host=roach-seattle-1:172.27.0.11 \
 --add-host=roach-seattle-2:172.27.0.12 \
 --add-host=roach-seattle-3:172.27.0.13 \
 -p 26258:26257 \
 -p 8080:8080 \
 -v "roach-seattle-1-data:/cockroach/cockroach-data" \
 -v $PWD/CockroachDB_files:/CockroachDB_files:ro \
 cockroachdb/cockroach:$COCKROACHDB_VERSION \
 start \
  --insecure \
  --store=cockroach-data,ballast-size=0 \
  --join=roach-seattle-1 \
  --locality=region=us-west2,zone=a

echo
echo 'Next step: Create the Docker container for CockroachDB 2 in Seattle'
pause
echo 'Creating the Docker container for CockroachDB 2 in Seattle'

docker run \
 -d \
 --name=roach-seattle-2 \
 --hostname=roach-seattle-2 \
 --ip=172.27.0.12 \
 --net=us-west2-net \
 --add-host=roach-seattle-1:172.27.0.11 \
 --add-host=roach-seattle-2:172.27.0.12 \
 --add-host=roach-seattle-3:172.27.0.13 \
 -p 26259:26257 \
 -p 8081:8080 \
 -v "roach-seattle-2-data:/cockroach/cockroach-data" \
 -v $PWD/CockroachDB_files:/CockroachDB_files:ro \
 cockroachdb/cockroach:$COCKROACHDB_VERSION \
 start \
  --insecure \
  --store=cockroach-data,ballast-size=0 \
  --join=roach-seattle-1 \
  --locality=region=us-west2,zone=b

echo
echo 'Next step: Create the Docker container for CockroachDB 3 in Seattle'
pause
echo 'Creating the Docker container for CockroachDB 3 in Seattle'

docker run \
 -d \
 --name=roach-seattle-3 \
 --hostname=roach-seattle-3 \
 --ip=172.27.0.13 \
 --net=us-west2-net \
 --add-host=roach-seattle-1:172.27.0.11 \
 --add-host=roach-seattle-2:172.27.0.12 \
 --add-host=roach-seattle-3:172.27.0.13 \
 -p 26260:26257 \
 -p 8082:8080 \
 -v "roach-seattle-3-data:/cockroach/cockroach-data" \
 -v $PWD/CockroachDB_files:/CockroachDB_files:ro \
 cockroachdb/cockroach:$COCKROACHDB_VERSION \
 start \
  --insecure \
  --store=cockroach-data,ballast-size=0 \
  --join=roach-seattle-1 \
  --locality=region=us-west2,zone=c

echo
echo 'Next step: Create the Docker container for HAProxy in Seattle'
pause
echo 'Creating the Docker container for HAProxy in Seattle'

# Seattle HAProxy
docker run \
 -d \
 --name haproxy-seattle \
 --ip=172.27.0.10 \
 -p 26257:26257 \
 --net=us-west2-net \
 -v $PWD/haproxy_data/us-west2/:/usr/local/etc/haproxy:ro \
 haproxy:$HAPROXY_VERSION  

echo
echo 'Next step: Initialize the CockroachDB cluster'
pause
echo 'Initializing the CockroachDB cluster'

# Initialize the CockroachDB cluster
docker exec -it roach-seattle-1 ./cockroach init --insecure

sleep 3

# Show CockroachDB startup log info for each node
echo
echo 'Next step: Show CockroachDB startup log info for each node'
pause
echo
echo 'Node 1 startup info:'
docker exec -it roach-seattle-1 grep 'node starting' /cockroach/cockroach-data/logs/cockroach.log -A 14

echo
echo 'Node 2 startup info:'
docker exec -it roach-seattle-2 grep 'node starting' /cockroach/cockroach-data/logs/cockroach.log -A 14

echo
echo 'Node 3 startup info:'
docker exec -it roach-seattle-3 grep 'node starting' /cockroach/cockroach-data/logs/cockroach.log -A 14
echo

echo 'Initial databases:'

docker exec roach-seattle-1 ./cockroach sql --insecure --format table -e 'SHOW DATABASES'

echo
echo 'Load DB schema on CockroachDB'
echo '(no data, no constraints, no indexes)'
pause

docker exec \
 roach-seattle-1 \
 ./cockroach sql \
  --insecure \
  --file /CockroachDB_files/Chinook_CockroachDB_from_MySql_NO_DATA_NO_CONSTRAINTS_NO_INDEXES.sql

echo
echo 'After loading schema - databases and tables:'
echo
docker exec roach-seattle-1 ./cockroach sql --insecure --format table -e 'SHOW DATABASES'
echo
docker exec roach-seattle-1 ./cockroach sql --insecure --database chinook --format table -e 'SHOW TABLES'

echo
echo 'Prepare to perform the bulk data copy using MOLT Fetch...'
echo
echo 'Verify the first binary log has been flushed.'
echo 'This query should return a result.'
echo 'At this point, if it does NOT return a result, something is wrong and the subsequent MOLT Fetch command will fail.'
pause

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --table -e 'SELECT @@global.gtid_executed'

echo
echo 'Perform the bulk data copy using MOLT Fetch in --direct-copy mode'
pause

docker run \
 --name=molt_fetch \
 --hostname=molt_fetch_host \
 --ip=172.27.0.102 \
 --net=us-west2-net \
 cockroachdb/molt \
  fetch \
  --logging debug \
  --mode data-load \
  --direct-copy \
  --allow-tls-mode-disable \
  --source "mysql://root:$MYSQL_ROOT_PASSWORD@mysql_host:3306/Chinook" \
  --target 'postgres://root@roach-seattle-1:26257/chinook?sslmode=disable' \
| tee molt_fetch_output.txt

echo
echo 'Get the CDC Cursor for later use with MOLT Replicator so we can start streaming'
echo 'changes from the right point.'
pause

CDC_CURSOR=$(grep cdc_cursor molt_fetch_output.txt | head -n 1 | sed 's/.*cdc_cursor":"//' | sed 's/".*//')

echo "CDC Cursor is: $CDC_CURSOR"

echo
echo 'Show CockroachDB table row counts after bulk copy'
pause

docker exec roach-seattle-1 ./cockroach sql --insecure --database chinook --format table -e 'SELECT count(*) AS album_count_cockroachdb FROM album'
echo
docker exec roach-seattle-1 ./cockroach sql --insecure --database chinook --format table -e 'SELECT count(*) AS artist_count_cockroachdb FROM artist'

echo
echo 'Use MOLT Verify to compare MySQL source data to CockroachDB target data'
echo '(Note: Any source DB activity between MOLT Fetch and MOLT Verify could produce false differences)'
pause

docker run \
 --name=molt_verify \
 --hostname=molt_verify_host \
 --ip=172.27.0.103 \
 --net=us-west2-net \
 cockroachdb/molt \
  verify \
  --table-filter '[^_].*' \
  --allow-tls-mode-disable \
  --source "mysql://root:$MYSQL_ROOT_PASSWORD@mysql_host:3306/Chinook" \
  --target 'postgres://root@roach-seattle-1:26257/chinook?sslmode=disable' \
| tee molt_verify_output.txt

echo
echo 'Pretty-print MOLT Verify output'
pause

cat molt_verify_output.txt | tail -n +2 | jq

echo
echo 'Generate source database traffic to simulate ongoing operation outside scheduled downtime'
echo
echo "Insert $NUM_NEW_ARTISTS_MYSQL new Artists"
pause

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
 "INSERT INTO Artist (ArtistID, Name) (
    WITH RECURSIVE NumberSeries AS (
      SELECT 1 AS n
      UNION ALL
      SELECT n + 1 FROM NumberSeries WHERE n < $NUM_NEW_ARTISTS_MYSQL
      ), 
    cte2 AS (
      SELECT n, UUID() AS u FROM NumberSeries
      ), 
    cte3 AS (
      SELECT max(ArtistID) AS max_artist FROM Artist
      ) 
    SELECT cte2.n + cte3.max_artist AS ArtistID, concat('Artist_', u) AS Name 
    FROM cte2 JOIN cte3 ON TRUE)"

echo
echo "Insert $NUM_NEW_ALBUMS_MYSQL new Albums"
pause

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
 "INSERT INTO Album (AlbumID, TItle, ArtistID) (
    WITH RECURSIVE NumberSeries AS (
      SELECT 1 AS n
      UNION ALL
      SELECT n + 1 FROM NumberSeries WHERE n < $NUM_NEW_ALBUMS_MYSQL
      ), 
    cte2 AS (
      SELECT n, UUID() AS u FROM NumberSeries
      ), 
    cte3 AS (
      SELECT max(ArtistID) AS max_artist FROM Artist
      ), 
    cte4 AS (
      SELECT max(AlbumId) AS max_albumid 
      FROM Album
      ) 
    SELECT cte2.n + cte4.max_albumid AS AlbumID, 
           CONCAT('Title_', u) as Title, 
           CAST(rand()*(cte3.max_artist-1) AS SIGNED)+1 AS ArtistID
    FROM cte2 JOIN cte3 ON TRUE JOIN cte4 ON TRUE)"

echo
echo 'Set up streaming replication using MOLT Replicator'
pause

docker run \
 -d \
 --name=replicator_forward \
 --hostname=molt_replicator_host \
 --ip=172.27.0.104 \
 --net=us-west2-net \
 cockroachdb/replicator \
  mylogical \
  -v \
  --defaultGTIDSet $CDC_CURSOR \
  --stagingSchema _replicator \
  --stagingCreateSchema \
  --targetSchema chinook.public \
  --sourceConn "mysql://root:$MYSQL_ROOT_PASSWORD@mysql_host:3306/Chinook?sslmode=disable" \
  --targetConn 'postgres://root@roach-seattle-1:26257/chinook?sslmode=disable'

sleep 3

echo
echo 'View MOLT Replicator log output'
pause;

docker logs replicator_forward

echo
echo 'Demonstrate replication'
echo
echo First show the number of artists in MySQL and CockroachDB
pause

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e 'SELECT count(*) AS artist_count_mysql FROM Artist'
echo
docker exec roach-seattle-1 cockroach sql --insecure --database chinook --format table -e 'SELECT count(*) AS artist_count_cockroachdb FROM artist'

echo
echo "Insert $NUM_NEW_ARTISTS_MYSQL2 more artists in MySQL"
pause

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
 "INSERT INTO Artist (ArtistID, Name) (
    WITH RECURSIVE NumberSeries AS (
      SELECT 1 AS n
      UNION ALL
      SELECT n + 1 FROM NumberSeries WHERE n < $NUM_NEW_ARTISTS_MYSQL2
      ),
    cte2 AS (
      SELECT n, UUID() AS u FROM NumberSeries
      ),
    cte3 AS (
      SELECT max(ArtistID) AS max_artist FROM Artist
      )
    SELECT cte2.n + cte3.max_artist AS ArtistID, concat('Artist_', u) AS Name
    FROM cte2 JOIN cte3 ON TRUE)"

echo
echo 'Again show the number of artists in MySQL and CockroachDB'
pause

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e 'SELECT count(*) AS artist_count_mysql FROM Artist'
echo
docker exec roach-seattle-1 cockroach sql --insecure --database chinook --format table -e 'SELECT count(*) AS artist_count_cockroachdb FROM artist'

echo
echo 'Now use MOLT Verify again, just on the Artist table'
pause

docker run \
 --name=molt_verify_2 \
 --hostname=molt_verify_host \
 --ip=172.27.0.103 \
 --net=us-west2-net \
 cockroachdb/molt \
  verify \
  --table-filter 'Artist' \
  --allow-tls-mode-disable \
  --source "mysql://root:$MYSQL_ROOT_PASSWORD@mysql_host:3306/Chinook" \
  --target 'postgres://root@roach-seattle-1:26257/chinook?sslmode=disable' \
| tail -n +2 | jq

echo
echo 'Again view MOLT Replicator log output'
pause

docker logs replicator_forward

echo
echo 'Prepare for scheduled downtime.'
echo 'Set up reverse replication for failback using MOLT Replicator'
echo
echo 'Next step: Generate certificate authority (CA) certificate and private key'
pause
echo 'Generating certificate authority (CA) certificate and private key'

mkdir certs
mkdir my-safe-directory

docker run \
 --rm \
 --name temp_crdb \
 -v $PWD/certs:/certs \
 -v $PWD/my-safe-directory:/my-safe-directory \
 cockroachdb/cockroach:$COCKROACHDB_VERSION \
 cert create-ca \
  --certs-dir=/certs \
  --ca-key=/my-safe-directory/ca.key

echo
ls -l certs my-safe-directory

# Generate MOLT Replicator webhook TLS/endpoint certificate and private key
echo
echo 'Next step: Generate MOLT Replicator webhook TLS/endpoint certificate and private key'
pause
echo 'Generating MOLT Replicator webhook TLS/endpoint certificate and private key'

docker run \
 --rm \
 --name temp_crdb \
 -v $PWD/certs:/certs \
 -v $PWD/my-safe-directory:/my-safe-directory \
 cockroachdb/cockroach:$COCKROACHDB_VERSION \
 cert create-node \
  molt_replicator_host \
  --certs-dir=/certs \
  --ca-key=/my-safe-directory/ca.key 

echo
ls -l certs my-safe-directory

echo
echo 'Now base64-encode and URL-encode the TLS/endpoint certificate and private key'
echo 'and the CA certificate for use later in the CREATE CHANGEFEED statement.'
pause

NODE_CERT_BASE64_URL_ENCODED=$(base64 -i certs/node.crt | jq -R -r '@uri')
NODE_KEY_BASE64_URL_ENCODED=$(base64 -i certs/node.key | jq -R -r '@uri')
CA_CERT_BASE64_URL_ENCODED=$(base64 -i certs/ca.crt | jq -R -r '@uri')

echo
echo 'TLS/endpoint certificate base64-encoded and URL-encoded:'
echo
echo $NODE_CERT_BASE64_URL_ENCODED
echo 
echo 'TLS/endpoint key base64-encoded and URL-encoded:'
echo
echo $NODE_KEY_BASE64_URL_ENCODED
echo
echo 'TLS/endpoint key base64-encoded and URL-encoded:'
echo
echo $CA_CERT_BASE64_URL_ENCODED

echo
echo 'Enable rangefeeds for change data capture for reverse migration'
pause

docker exec roach-seattle-1 cockroach sql --insecure --database chinook --format table -e 'SET CLUSTER SETTING kv.rangefeed.enabled = true'

echo
echo '-- START DOWNTIME --'
echo
echo 'Stop MySQL application traffic.'
echo 'Wait for replication pipeline to drain.'
echo 'Wait at least as long as the MOLT Replicator --flushPeriod setting if specified,'
echo 'or at least 30 seconds if not specified.'
pause

echo
echo 'Check that replication pipeline has drained'
echo
echo 'Look at "upserted rows" lines in the MOLT Replicator log output'
pause

docker logs replicator_forward 2>&1 | grep 'upserted rows'

echo
echo 'Stop MOLT Replicator forward migration'
pause

docker stop replicator_forward

echo
echo 'Add constraints and indexes to CockroachDB database schema'
pause

echo
echo 'Start MOLT Replicator for the reverse migration'
pause

docker run \
 -d \
 --name=replicator_reverse \
 --hostname=molt_replicator_host \
 --ip=172.27.0.104 \
 --net=us-west2-net \
 -p 30004:30004 \
 -v $PWD/certs:/certs \
 cockroachdb/replicator \
  start \
  -v \
  --stagingSchema _replicator \
  --bindAddr :30004 \
  --metricsAddr :30005 \
  --disableAuthentication \
  --targetConn "mysql://root:$MYSQL_ROOT_PASSWORD@mysql_host:3306/Chinook?sslmode=disable" \
  --stagingConn 'postgres://root@roach-seattle-1:26257/chinook?sslmode=disable' \
  --tlsCertificate /certs/node.crt \
  --tlsPrivateKey /certs/node.key

echo
echo 'Look at MOLT Replicator logs'
pause

docker logs replicator_reverse

echo
echo 'Get the CockroachCB cluster logical timestamp for the changefeed cursor parameter'
pause

CLUSTER_LOGICAL_TIMESTAMP=$(docker exec roach-seattle-1 cockroach sql --insecure --database chinook --format csv -e 'SELECT cluster_logical_timestamp()' | tail -n -1)

echo
echo "Cluster logical timestamp: $CLUSTER_LOGICAL_TIMESTAMP"

echo
echo 'Create changefeed to MOLT Replicator'
pause

docker exec roach-seattle-1 cockroach sql --insecure --database chinook --format table -e \
"CREATE CHANGEFEED FOR TABLE album, artist, customer, employee, genre, invoice, invoiceline, mediatype, playlist, playlisttrack, track
 INTO 'webhook-https://molt_replicator_host:30004/Chinook?client_cert=$NODE_CERT_BASE64_URL_ENCODED&client_key=$NODE_KEY_BASE64_URL_ENCODED&ca_cert=$CA_CERT_BASE64_URL_ENCODED' 
 WITH updated, 
      resolved = '250ms', 
      min_checkpoint_frequency = '250ms', 
      initial_scan = 'no', 
      cursor = '$CLUSTER_LOGICAL_TIMESTAMP', 
      webhook_sink_config = '{\"Flush\":{\"Bytes\":1048576,\"Frequency\":\"1s\"}}'"

echo
echo 'Reverse replication is set up'
pause

echo
echo 'Switch application to start using CockroachDB'
echo 'Validate application'
echo 'Perform final go-no-go tests'
pause

echo '-- END DOWNTIME --'
echo
echo 'Migration is complete.'
pause

echo
echo 'Show reverse replication is working'
echo
echo 'First show the number of playlists in MySQL and CockroachDB'

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e 'SELECT count(*) AS playlist_count_mysql FROM Playlist'
echo  
docker exec roach-seattle-1 cockroach sql --insecure --database chinook --format table -e 'SELECT count(*) AS playlist_count_cockroachdb FROM playlist'

echo
echo 'Insert a new playlist'
pause

docker exec roach-seattle-1 cockroach sql --insecure --database chinook --format table -e \
"INSERT INTO PLAYLIST (playlistid, name) (
  WITH cte AS (
   SELECT max(playlistid) AS max_playlistid FROM playlist)
  SELECT cte.max_playlistid + 1 AS playlistid, 'AI-Generated Favorites' AS name
  FROM cte
)"

echo
echo "Sleep $REVERSE_REPLICATION_LATENCY_SLEEP seconds to let the change propagate to MySQL"
sleep $REVERSE_REPLICATION_LATENCY_SLEEP

echo
echo 'Again show the number of playlists in MySQL and CockroachDB'

docker exec my-mysql-db mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e 'SELECT count(*) AS playlist_count_mysql FROM Playlist'
echo
docker exec roach-seattle-1 cockroach sql --insecure --database chinook --format table -e 'SELECT count(*) AS playlist_count_cockroachdb FROM playlist'

echo
echo 'Look at MOLT Replicator logs again'
pause

docker logs replicator_reverse

echo
echo '-- End of script --'
