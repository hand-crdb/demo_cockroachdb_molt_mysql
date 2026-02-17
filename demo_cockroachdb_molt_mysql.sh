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

# Variable definitions
# NOTE: You must export variables that will be displayed expanded in displayed commands
# WARNING: Credentials below are for local demo only. Use a secrets manager in production.

# Docker container versions (can specify "latest" too)
export MYSQL_VERSION='8.4.6'
export COCKROACHDB_VERSION='v25.2.8'
export HAPROXY_VERSION='1.7'

MYSQL_ROOT_PASSWORD='root_root_root'
export MYSQL_STARTUP_SLEEP=20
export REVERSE_REPLICATION_LATENCY_SLEEP=10
export NUM_NEW_ARTISTS_MYSQL=50
export NUM_NEW_ARTISTS_MYSQL2=10
export NUM_NEW_ALBUMS_MYSQL=50
export CDC_CURSOR=''

TEXT_WIDTH="100"
STAGE=1
TOTALSTAGES="9"
NOPAUSE=0
RESET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nopause|-n)
            NOPAUSE=1
            shift
            ;;
        --reset|-r)
            RESET=1
            shift
            ;;
        *)
            echo "Error: Unknown option $1" >&2
            echo "Usage: $0 [--nopause|-n] [--reset|-r]" >&2
            exit 1
            ;;
    esac
done

# ========================
# --reset option: tear down all containers, networks, and generated files
# ========================
if [[ $RESET == "1" ]]; then
  echo "Resetting environment..."

  echo "Stopping and removing containers..."
  docker rm -f my-mysql-db 2>/dev/null || true
  docker rm -f roach-seattle-1 roach-seattle-2 roach-seattle-3 2>/dev/null || true
  docker rm -f haproxy-seattle 2>/dev/null || true
  docker rm -f replicator_forward replicator_reverse 2>/dev/null || true
  docker rm -f molt_fetch molt_verify molt_verify_2 2>/dev/null || true
  docker network rm us-west2-net 2>/dev/null || true

  echo "Removing generated files and directories..."
  rm -rf certs_cockroachdb_ca certs_cockroachdb_1 certs_cockroachdb_2 certs_cockroachdb_3
  rm -rf certs_cockroachdb_clients certs_replicator_reverse
  rm -rf my_safe_directory_cockroachdb my_safe_directory_replicator_reverse
  rm -rf roach-seattle-1-data roach-seattle-2-data roach-seattle-3-data
  rm -rf haproxy_data
  rm -f molt_fetch_output.txt molt_verify_output.txt

  echo "Environment fully reset."
  exit 0
fi

# Cross-platform base64 encode (macOS uses -i, GNU uses positional arg)
b64_encode() {
  if [[ "$(uname)" == "Darwin" ]]; then
    base64 -i "$1"
  else
    base64 -w0 "$1"
  fi
}

pause() {
  PAUSE_TEXT="⏸️   Press [Enter] to execute this step..."
  if [[ $# -ne 0 ]]; then
    PAUSE_TEXT="✅   Press [Enter] to continue to the next step..."
  fi
 
  if [[ $NOPAUSE == "1" ]]; then
      sleep 1
    else
      read -p "${PAUSE_TEXT}"
  fi
  echo
}

print_text() {
  if [ -n "$1" ]; then
    echo "🛠️  $1" | fold -s -w $TEXT_WIDTH
  fi
}

# Print the command to be executed
# Print it with a single blank line before and after the command
# If the command already has any blank lines before or after the command, remove them.
# Blank lines are either empty lines or lines that only contain whitespace
# ref: https://stackoverflow.com/questions/12524308/bash-strip-trailing-linebreak-from-output
print_cmd() {
  param=$1
  trailing_space_removed=${param%[[:space:]]}
  leading_and_trailing_space_removed=${trailing_space_removed##[[:space:]]}
  echo
  echo "$leading_and_trailing_space_removed" | envsubst $2
#STH#  echo "$1" | envsubst $2
  echo
}

print_title() {
  echo "🚀 [$STAGE/$TOTALSTAGES] $1..."
  echo
  ((STAGE++))
}

# Parameters:
# 1: The stage title or empty string
# 2: Text to describe the current step or empty string
# 3: Command to display and execute
#    The command may have leading or trailing blank lines
#    (where a blank line is either an empty line or a line of only whitespace)
#    The command may be multi-line, using backslash at the end of line as a continuation character
#    The command may have variable references in it
# 4: List of variables to be substituted, or the word "noexpand"
#    The list is in the form $VAR1:$VAR2:$VAR3 including dollar signs (so enclose in single quotes).
#    Any variables not listed will not be expanded in the displayed command
# 5: [OPTIONAL] Whether to pause after displaying the command and before running it.
#    To not pause at all, specify "nopause"
#    To just pause after execution, specify "pause_after"
#    To pause both before and after execution, do not specify this parameter at all
do_stage() {
  if [[ -n "$1" ]]; then
    print_title "$1"
  fi  
  if [[ -n "$2" ]]; then
    print_text "$2"
  fi
  echo
  if [[ -n "$3" ]]; then
    echo "Next command:"
    echo "------------"
    print_cmd "$3" "$4"
    if [[ $# -ne 5 ]]; then
        pause
    fi
    echo "---Running"
    # Note: eval is required because CMD strings reference shell functions and variables
    # from this script. Variables set inside eval (e.g. CDC_CURSOR, CLUSTER_LOGICAL_TIMESTAMP)
    # persist in the current shell and are available to subsequent stages.
    eval "$3"
    echo "---Done"
    echo
    if [[ $# -ne 5 ]]; then
        pause post_icon
    elif [[ "$5" == "pause_after" ]]; then
        pause post_icon
    fi
  fi
}

TITLE='Create the region network for Docker containers to use'
TEXT='Creating the region network'
CMD=$(cat <<'EOFHERE'
docker network create --driver=bridge --subnet=172.27.0.0/16 --ip-range=172.27.0.0/24 --gateway=172.27.0.1 us-west2-net
EOFHERE
)
do_stage "$TITLE" "$TEXT" "$CMD" ''

TITLE='Setting up MySQL...'
TEXT='Start MySQL

Ref: https://hub.docker.com/_/mysql'
CMD=$(cat <<'EOFHERE'
docker run \
 -d \
 --name my-mysql-db \
 --hostname=mysql_host \
 --ip=172.27.0.101 \
 --net=us-west2-net \
 -e MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD \
 -p 3306:3306 \
 -v ./mysql_files:/mysql_files:ro \
 mysql:$MYSQL_VERSION
EOFHERE
)
do_stage "$TITLE" "$TEXT" "$CMD" '$MYSQL_VERSION'

TEXT="Sleeping $MYSQL_STARTUP_SLEEP seconds...

(imagine seeing dumb jokes being displayed every few seconds to pass the time)

MySQL needs to be given time to become ready for connections.
This is different from CockroachDB, which does not return control after being
started until it is ready to accept connections.

This initial wait happens in 2 steps:
1. Sleep unconditionally for a while (in this case $MYSQL_STARTUP_SLEEP seconds).
2. Additionally, wait for an admin MySQL ping command to return (it will block until MySQL is ready)."
CMD=$(cat <<'EOFHERE'
sleep $MYSQL_STARTUP_SLEEP
EOFHERE
)
do_stage '' "$TEXT" "$CMD" '$MYSQL_STARTUP_SLEEP' nopause

TEXT="MySQL has started.  Waiting for it to start accepting connections..."
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysqladmin ping -h localhost -u root --password=$MYSQL_ROOT_PASSWORD --wait=30
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand pause_after

TEXT='Initial set of databases:'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SHOW DATABASES'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Create database schema and populate with initial data'
CMD=$(cat <<'EOFHERE'
docker exec -i my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD < MySQL_files/Chinook_MySql.sql
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='List databases and tables in Chinook database'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SHOW DATABASES'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
  'SHOW TABLES'
EOFHERE
)
do_stage '' '' "$CMD" noexpand pause_after

TEXT='Look at data samples

Album:'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
  'SELECT * FROM Album ORDER BY AlbumID LIMIT 5'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

TEXT='Artist:'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
  'SELECT * FROM Artist ORDER BY ArtistID LIMIT 5'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

TEXT='Customer:'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
  'SELECT * FROM Customer ORDER BY CustomerID LIMIT 2\G'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

TEXT='Employee:'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
  'SELECT * FROM Employee ORDER BY EmployeeID LIMIT 2\G'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

TEXT='Genre:'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
  'SELECT * FROM Genre ORDER BY GenreID LIMIT 5'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

TEXT='Invoice:'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
  'SELECT * FROM Invoice ORDER BY InvoiceID LIMIT 5'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

TEXT='InvoiceLine:'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
  'SELECT * FROM InvoiceLine ORDER BY InvoiceLineID LIMIT 5'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

TEXT='MediaType:'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
  'SELECT * FROM MediaType ORDER BY MediaTypeID LIMIT 5'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

TEXT='Playlist:'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
  'SELECT * FROM Playlist ORDER BY PlaylistID LIMIT 5'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

TEXT='PlaylistTrack:'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
  'SELECT * FROM PlaylistTrack ORDER BY TrackID LIMIT 5'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

TEXT='Track:'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
  'SELECT * FROM Track ORDER BY TrackID LIMIT 3\G'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand pause_after

TEXT='Configure GTID-based replication...

Reference: https://dev.mysql.com/doc/refman/8.4/en/replication-mode-change-online-enable-gtids.html

Show the initial GTID settings'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SHOW VARIABLES LIKE '\''%gtid%'\'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Next step: set enforce_gtid_consistency to WARN'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SET @@GLOBAL.enforce_gtid_consistency = WARN'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SHOW VARIABLES LIKE '\''%gtid%'\'
EOFHERE
)
do_stage '' '' "$CMD" noexpand nopause

TEXT='Next step: set enforce_gtid_consistency to ON'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SET @@GLOBAL.enforce_gtid_consistency = ON'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SHOW VARIABLES LIKE '\''%gtid%'\'
EOFHERE
)
do_stage '' '' "$CMD" noexpand nopause

TEXT='Next step: set gtid_mode to OFF_PERMISSIVE'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SET @@GLOBAL.gtid_mode = OFF_PERMISSIVE'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SHOW VARIABLES LIKE '\''%gtid%'\'
EOFHERE
)
do_stage '' '' "$CMD" noexpand nopause

TEXT='Next step: set gtid_mode to ON_PERMISSIVE'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SET @@GLOBAL.gtid_mode = ON_PERMISSIVE'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SHOW VARIABLES LIKE '\''%gtid%'\'
EOFHERE
)
do_stage '' '' "$CMD" noexpand nopause

TEXT='Next step: set binlog_row_metadata to FULL'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SET @@GLOBAL.BINLOG_ROW_METADATA = FULL'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SHOW VARIABLES LIKE '\''%binlog%'\'
EOFHERE
)
do_stage '' '' "$CMD" noexpand nopause

TEXT='Next step: Check for ongoing transactions'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SHOW STATUS LIKE '\''Ongoing%'\'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

TEXT='Next step: set gtid_mode to ON'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SET @@GLOBAL.GTID_MODE = ON'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SHOW VARIABLES LIKE '\''%gtid%'\'

sleep 1
EOFHERE
)
do_stage '' '' "$CMD" noexpand pause_after

TEXT='Generate some synthetic write traffic to get the first binary log to be flushed.

At that point there will be a start and end to the GTID so GTID-based
replication can start to be used.

Create a temporary database for the synthetic write traffic'

CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'CREATE DATABASE temp_delete'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Create a table in the temporary database'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=temp_delete --table -e \
  'CREATE TABLE t (pk SERIAL PRIMARY KEY, fname VARCHAR(100), lname VARCHAR(100), age integer)'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Populate the table with some data

(Note we have to use a recursive CTE to generate a series of numbers)'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=temp_delete --table -e \
  "INSERT INTO t (fname, lname, age) 
    (WITH RECURSIVE NumberSeries AS (
      SELECT 1 AS n -- Anchor member: starting value
      UNION ALL
      SELECT n + 1 FROM NumberSeries WHERE n < 1000 -- Recursive member: increments and termination condition
    )
    SELECT concat('F', CAST((rand()*100.0) AS SIGNED)), concat('L', CAST((rand()*100.0) AS SIGNED)), CAST((rand()*100.0) AS SIGNED) 
    FROM NumberSeries)"

sleep 2
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='See some rows just added:'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=temp_delete --table -e \
  "SELECT * FROM t LIMIT 10"
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Verify the first binary log has been flushed.

This query should return a result.
Even if it does not, proceed anyway - we will check this again later, right before we need it.'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SELECT @@global.gtid_executed'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Drop the temporary database used for synthetic write traffic'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD -e \
  'DROP DATABASE IF EXISTS temp_delete'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

TITLE='Setting up CockroachDB...'

# Set up CockroachDB
# Ref: https://www.cockroachlabs.com/blog/simulate-cockroachdb-cluster-localhost-docker/

TEXT='Next step: Create the haproxy.cfg file for HAProxy

Creating the haproxy.cfg file'

CMD=$(cat <<'EOFHERE'
mkdir -p haproxy_data/us-west2

cat - >haproxy_data/us-west2/haproxy.cfg <<'EOFHERE2'

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

EOFHERE2
EOFHERE
)
do_stage "$TITLE" "$TEXT" "$CMD" noexpand

TEXT='Next step: Generate certificate authority (CA) certificate and private key for CockroachDB'
CMD=$(cat <<'EOFHERE'
mkdir certs_cockroachdb_ca my_safe_directory_cockroachdb

docker run \
 --rm \
 --name temp_crdb \
 -v ./certs_cockroachdb_ca:/certs_cockroachdb_ca \
 -v ./my_safe_directory_cockroachdb:/my_safe_directory_cockroachdb \
 cockroachdb/cockroach:$COCKROACHDB_VERSION \
  cert create-ca \
   --certs-dir=/certs_cockroachdb_ca \
   --ca-key=/my_safe_directory_cockroachdb/ca.key

echo
ls -l certs_cockroachdb_ca my_safe_directory_cockroachdb
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Next step: Generate Cockroachdb node 1 certificate and private key'
CMD=$(cat <<'EOFHERE'
mkdir certs_cockroachdb_1
cp certs_cockroachdb_ca/ca.crt certs_cockroachdb_1

docker run \
 --rm \
 --name temp_crdb \
 -v ./certs_cockroachdb_1:/certs_cockroachdb_1 \
 -v ./my_safe_directory_cockroachdb:/my_safe_directory_cockroachdb \
 cockroachdb/cockroach:$COCKROACHDB_VERSION \
  cert create-node \
   roach-seattle-1 \
   --certs-dir=/certs_cockroachdb_1 \
   --ca-key=/my_safe_directory_cockroachdb/ca.key 

echo
ls -l certs_cockroachdb_1 my_safe_directory_cockroachdb
EOFHERE
)
do_stage '' "$TEXT" "$CMD" '$COCKROACHDB_VERSION'

TEXT='Next step: Generate Cockroachdb node 2 certificate and private key'
CMD=$(cat <<'EOFHERE'
mkdir certs_cockroachdb_2
cp certs_cockroachdb_ca/ca.crt certs_cockroachdb_2

docker run \
 --rm \
 --name temp_crdb \
 -v ./certs_cockroachdb_2:/certs_cockroachdb_2 \
 -v ./my_safe_directory_cockroachdb:/my_safe_directory_cockroachdb \
 cockroachdb/cockroach:$COCKROACHDB_VERSION \
  cert create-node \
   roach-seattle-2 \
   --certs-dir=/certs_cockroachdb_2 \
   --ca-key=/my_safe_directory_cockroachdb/ca.key 

echo
ls -l certs_cockroachdb_2 my_safe_directory_cockroachdb
EOFHERE
)
do_stage '' "$TEXT" "$CMD" '$COCKROACHDB_VERSION'

TEXT='Next step: Generate Cockroachdb node 3 certificate and private key'
CMD=$(cat <<'EOFHERE'
mkdir certs_cockroachdb_3
cp certs_cockroachdb_ca/ca.crt certs_cockroachdb_3

docker run \
 --rm \
 --name temp_crdb \
 -v ./certs_cockroachdb_3:/certs_cockroachdb_3 \
 -v ./my_safe_directory_cockroachdb:/my_safe_directory_cockroachdb \
 cockroachdb/cockroach:$COCKROACHDB_VERSION \
  cert create-node \
   roach-seattle-3 \
   --certs-dir=/certs_cockroachdb_3 \
   --ca-key=/my_safe_directory_cockroachdb/ca.key 

echo
ls -l certs_cockroachdb_3 my_safe_directory_cockroachdb
EOFHERE
)
do_stage '' "$TEXT" "$CMD" '$COCKROACHDB_VERSION'

TEXT='Next step: Generate root client certificate and private key'
CMD=$(cat <<'EOFHERE'
mkdir certs_cockroachdb_clients
cp certs_cockroachdb_ca/ca.crt certs_cockroachdb_clients

docker run \
 --rm \
 --name temp_crdb \
 -v ./certs_cockroachdb_clients:/certs_cockroachdb_clients \
 -v ./my_safe_directory_cockroachdb:/my_safe_directory_cockroachdb \
 cockroachdb/cockroach:$COCKROACHDB_VERSION \
  cert create-client \
   root \
   --certs-dir=/certs_cockroachdb_clients \
   --ca-key=/my_safe_directory_cockroachdb/ca.key

cp certs_cockroachdb_clients/client.root.crt certs_cockroachdb_1
cp certs_cockroachdb_clients/client.root.key certs_cockroachdb_1
cp certs_cockroachdb_clients/client.root.crt certs_cockroachdb_2
cp certs_cockroachdb_clients/client.root.key certs_cockroachdb_2
cp certs_cockroachdb_clients/client.root.crt certs_cockroachdb_3
cp certs_cockroachdb_clients/client.root.key certs_cockroachdb_3

echo
ls -l certs_cockroachdb_clients certs_cockroachdb_1 certs_cockroachdb_2 certs_cockroachdb_3 my_safe_directory_cockroachdb
EOFHERE
)
do_stage '' "$TEXT" "$CMD" '$COCKROACHDB_VERSION'

TEXT='Next step: Create the Docker containers for the 3 CockroachDB nodes

Creating the Docker container for CockroachDB 1 in Seattle'
CMD=$(cat <<'EOFHERE'
mkdir roach-seattle-1-data

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
 -v ./certs_cockroachdb_1:/cockroach/certs:ro \
 -v ./roach-seattle-1-data:/cockroach/cockroach-data \
 -v ./CockroachDB_files:/CockroachDB_files:ro \
 cockroachdb/cockroach:$COCKROACHDB_VERSION \
  start \
   --certs-dir=certs \
   --store=cockroach-data,ballast-size=0 \
   --advertise-addr=roach-seattle-1:26357 \
   --listen-addr=roach-seattle-1:26357 \
   --http-addr=roach-seattle-1:8080 \
   --sql-addr=roach-seattle-1:26257 \
   --join=roach-seattle-1:26357,roach-seattle-2:26357,roach-seattle-3:26357 \
   --locality=region=us-west2,zone=a
EOFHERE
)
do_stage '' "$TEXT" "$CMD" '$COCKROACHDB_VERSION'

TEXT='Next step: Create the Docker container for CockroachDB 2 in Seattle'
CMD=$(cat <<'EOFHERE'
mkdir roach-seattle-2-data

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
 -v ./certs_cockroachdb_2:/cockroach/certs \
 -v ./roach-seattle-2-data:/cockroach/cockroach-data \
 -v ./CockroachDB_files:/CockroachDB_files:ro \
 cockroachdb/cockroach:$COCKROACHDB_VERSION \
  start \
   --certs-dir=certs \
   --store=cockroach-data,ballast-size=0 \
   --advertise-addr=roach-seattle-2:26357 \
   --listen-addr=roach-seattle-2:26357 \
   --http-addr=roach-seattle-2:8080 \
   --sql-addr=roach-seattle-2:26257 \
   --join=roach-seattle-1:26357,roach-seattle-2:26357,roach-seattle-3:26357 \
   --locality=region=us-west2,zone=b
EOFHERE
)
do_stage '' "$TEXT" "$CMD" '$COCKROACHDB_VERSION'

TEXT='Next step: Create the Docker container for CockroachDB 3 in Seattle'
CMD=$(cat <<'EOFHERE'
mkdir roach-seattle-3-data

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
 -v ./certs_cockroachdb_3:/cockroach/certs \
 -v ./roach-seattle-3-data:/cockroach/cockroach-data \
 -v ./CockroachDB_files:/CockroachDB_files:ro \
 cockroachdb/cockroach:$COCKROACHDB_VERSION \
  start \
   --certs-dir=certs \
   --store=cockroach-data,ballast-size=0 \
   --advertise-addr=roach-seattle-3:26357 \
   --listen-addr=roach-seattle-3:26357 \
   --http-addr=roach-seattle-3:8080 \
   --sql-addr=roach-seattle-3:26257 \
   --join=roach-seattle-1:26357,roach-seattle-2:26357,roach-seattle-3:26357 \
   --locality=region=us-west2,zone=c
EOFHERE
)
do_stage '' "$TEXT" "$CMD" '$COCKROACHDB_VERSION'

TEXT='Next step: Create the Docker container for HAProxy in Seattle'
CMD=$(cat <<'EOFHERE'
# Seattle HAProxy
docker run \
 -d \
 --name haproxy-seattle \
 --ip=172.27.0.10 \
 -p 26257:26257 \
 --net=us-west2-net \
 -v ./haproxy_data/us-west2/:/usr/local/etc/haproxy:ro \
 haproxy:$HAPROXY_VERSION  
EOFHERE
)
do_stage '' "$TEXT" "$CMD" '$HAPROXY_VERSION'

TEXT='Next step: Initialize the CockroachDB cluster'
CMD=$(cat <<'EOFHERE'
docker exec -i roach-seattle-1 \
 ./cockroach --host=roach-seattle-1:26357 init --certs-dir=certs

sleep 3
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Next step: Show CockroachDB startup log info for each node'
CMD=$(cat <<'EOFHERE'
echo 'Node 1 startup info:'
docker exec -i roach-seattle-1 \
 grep 'node starting' /cockroach/cockroach-data/logs/cockroach.log -A 14

echo
echo 'Node 2 startup info:'
docker exec -i roach-seattle-2 \
 grep 'node starting' /cockroach/cockroach-data/logs/cockroach.log -A 14

echo
echo 'Node 3 startup info:'
docker exec -i roach-seattle-3 \
 grep 'node starting' /cockroach/cockroach-data/logs/cockroach.log -A 14
EOFHERE
) 
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Initial databases:'
CMD=$(cat <<'EOFHERE'
docker exec roach-seattle-1 \
 ./cockroach --host=roach-seattle-1:26257 sql --certs-dir=certs --format table -e \
  'SHOW DATABASES'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Load DB schema on CockroachDB

(no data, no constraints, no indexes)'
CMD=$(cat <<'EOFHERE'
docker exec roach-seattle-1 \
 ./cockroach \
  --host=roach-seattle-1:26257 \
  sql \
  --certs-dir=certs \
  --file /CockroachDB_files/Chinook_CockroachDB_from_MySql_NO_DATA_NO_CONSTRAINTS_NO_INDEXES.sql
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='After loading schema - databases and tables:'
CMD=$(cat <<'EOFHERE'
docker exec roach-seattle-1 \
 ./cockroach --host=roach-seattle-1:26257 sql --certs-dir=certs --format table -e \
  'SHOW DATABASES'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand nopause

CMD=$(cat <<'EOFHERE'
docker exec roach-seattle-1 \
 ./cockroach --host=roach-seattle-1:26257 sql --certs-dir=certs --database chinook --format table -e \
  'SHOW TABLES'
EOFHERE
)
do_stage '' '' "$CMD" noexpand pause_after

TITLE='Bulk copy using MOLT Fetch'
TEXT='Prepare to perform the bulk data copy using MOLT Fetch...

Verify the first binary log has been flushed.
This query should return a result.
At this point, if it does NOT return a result, something is wrong and the subsequent MOLT Fetch command will fail.'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --table -e \
  'SELECT @@global.gtid_executed'
EOFHERE
)
do_stage "$TITLE" "$TEXT" "$CMD" noexpand

TEXT='Perform the bulk data copy using MOLT Fetch in --direct-copy mode'
CMD=$(cat <<'EOFHERE'
docker run \
 --rm \
 --name=molt_fetch \
 --hostname=molt_fetch_host \
 --ip=172.27.0.102 \
 --net=us-west2-net \
 -v ./certs_cockroachdb_clients:/app/certs \
 cockroachdb/molt \
  fetch \
   --logging debug \
   --mode data-load \
   --direct-copy \
   --allow-tls-mode-disable \
   --source "mysql://root:$MYSQL_ROOT_PASSWORD@mysql_host:3306/Chinook" \
   --target 'postgres://root@roach-seattle-1:26257/chinook?sslmode=verify-full&sslrootcert=certs%2Fca.crt&sslcert=certs%2Fclient.root.crt&sslkey=certs%2Fclient.root.key' \
| tee molt_fetch_output.txt
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand
#TODO specify MOLT version

TEXT='Get the CDC Cursor for later use with MOLT Replicator so we can start streaming changes from the right point.'
CMD=$(cat <<'EOFHERE'
CDC_CURSOR=$(grep cdc_cursor molt_fetch_output.txt | head -n 1 | jq -r '.cdc_cursor // empty' 2>/dev/null || grep cdc_cursor molt_fetch_output.txt | head -n 1 | sed 's/.*cdc_cursor":"//' | sed 's/".*//')

echo "CDC Cursor is: $CDC_CURSOR"
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Show CockroachDB table row counts after bulk copy'
CMD=$(cat <<'EOFHERE'
docker exec roach-seattle-1 \
 ./cockroach --host=roach-seattle-1:26257 sql --certs-dir=certs --database chinook --format table -e \
  'SELECT count(*) AS album_count_cockroachdb FROM album'

echo

docker exec roach-seattle-1 \
 ./cockroach --host=roach-seattle-1:26257 sql --certs-dir=certs --database chinook --format table -e \
  'SELECT count(*) AS artist_count_cockroachdb FROM artist'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Use MOLT Verify to compare MySQL source data to CockroachDB target data

(Note: Any source DB activity between MOLT Fetch and MOLT Verify could produce false differences)'
CMD=$(cat <<'EOFHERE'
docker run \
 --rm \
 --name=molt_verify \
 --hostname=molt_verify_host \
 --ip=172.27.0.103 \
 --net=us-west2-net \
 -v ./certs_cockroachdb_clients:/app/certs \
 cockroachdb/molt \
  verify \
   --table-filter '[^_].*' \
   --allow-tls-mode-disable \
   --source "mysql://root:$MYSQL_ROOT_PASSWORD@mysql_host:3306/Chinook" \
   --target 'postgres://root@roach-seattle-1:26257/chinook?sslmode=verify-full&sslrootcert=certs%2Fca.crt&sslcert=certs%2Fclient.root.crt&sslkey=certs%2Fclient.root.key' \
| tee molt_verify_output.txt
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Pretty-print MOLT Verify output'
CMD=$(cat <<'EOFHERE'
cat molt_verify_output.txt | tail -n +2 | jq
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT="Generate source database traffic to simulate ongoing operation outside scheduled downtime

Insert $NUM_NEW_ARTISTS_MYSQL new Artists"
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
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
EOFHERE
)
do_stage '' "$TEXT" "$CMD" '$NUM_NEW_ARTISTS_MYSQL'

TEXT="Insert $NUM_NEW_ALBUMS_MYSQL new Albums"
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
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
EOFHERE
)
do_stage '' "$TEXT" "$CMD" '$NUM_NEW_ALBUMS_MYSQL'

TEXT='Add constraints and indexes to CockroachDB database schema

Note: You could do this either before or after starting streaming replication.
- Doing it before lets you do it on an otherwise idle CockroachDB cluster.
  But if that takes a very long time then when you subsequently start
  MOLT Replicator, it will have more source data to catch up with.
- Doing it after keeps MOLT Replicator from having as much source data
  to catch up with.  But these potentially expensive DDL statements
  will have to happen concurrently with data changes that are being
  replicated from the source system.'
CMD=$(cat <<'EOFHERE'
echo 'TBD'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand pause_after

TITLE='Streaming replication using MOLT Replicator'
TEXT='Set up streaming replication'
CMD=$(cat <<'EOFHERE'
docker run \
 -d \
 --name=replicator_forward \
 --hostname=molt_replicator_host \
 --ip=172.27.0.104 \
 --net=us-west2-net \
 -v ./certs_cockroachdb_clients:/certs \
 cockroachdb/replicator \
  mylogical \
   -vv \
   --defaultGTIDSet $CDC_CURSOR \
   --stagingSchema _replicator \
   --stagingCreateSchema \
   --targetSchema chinook.public \
   --sourceConn "mysql://root:$MYSQL_ROOT_PASSWORD@mysql_host:3306/Chinook?sslmode=disable" \
   --targetConn 'postgres://root@roach-seattle-1:26257/chinook?sslmode=verify-full&sslrootcert=certs%2Fca.crt&sslcert=certs%2Fclient.root.crt&sslkey=certs%2Fclient.root.key'

sleep 3
EOFHERE
)
do_stage "$TITLE" "$TEXT" "$CMD" '$CDC_CURSOR'

TEXT='View MOLT Replicator log output'
CMD=$(cat <<'EOFHERE'
docker logs replicator_forward
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Demonstrate replication

First show the number of artists in MySQL and CockroachDB'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
  'SELECT count(*) AS artist_count_mysql FROM Artist'

echo

docker exec roach-seattle-1 \
 ./cockroach --host=roach-seattle-1:26257 sql --certs-dir=certs --database chinook --format table -e \
  'SELECT count(*) AS artist_count_cockroachdb FROM artist'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT="Insert $NUM_NEW_ARTISTS_MYSQL2 more artists in MySQL"
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
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
EOFHERE
)
do_stage '' "$TEXT" "$CMD" '$NUM_NEW_ARTISTS_MYSQL2'

TEXT='Again show the number of artists in MySQL and CockroachDB'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
  'SELECT count(*) AS artist_count_mysql FROM Artist'

echo

docker exec roach-seattle-1 \
 ./cockroach --host=roach-seattle-1:26257 sql --certs-dir=certs --database chinook --format table -e \
  'SELECT count(*) AS artist_count_cockroachdb FROM artist'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Now use MOLT Verify again, just on the Artist table'
CMD=$(cat <<'EOFHERE'
docker run \
 --rm \
 --name=molt_verify_2 \
 --hostname=molt_verify_host \
 --ip=172.27.0.103 \
 --net=us-west2-net \
 -v ./certs_cockroachdb_clients:/app/certs \
 cockroachdb/molt \
  verify \
   --table-filter 'Artist' \
   --allow-tls-mode-disable \
   --source "mysql://root:$MYSQL_ROOT_PASSWORD@mysql_host:3306/Chinook" \
   --target 'postgres://root@roach-seattle-1:26257/chinook?sslmode=verify-full&sslrootcert=certs%2Fca.crt&sslcert=certs%2Fclient.root.crt&sslkey=certs%2Fclient.root.key' \
| tail -n +2 | jq
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Again view MOLT Replicator log output'
CMD=$(cat <<'EOFHERE'
docker logs replicator_forward
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TITLE='Prepare for scheduled downtime'
TEXT='Set up reverse replication for failback using MOLT Replicator

Next step: Generate certificate authority (CA) certificate and private key'
CMD=$(cat <<'EOFHERE'
mkdir certs_replicator_reverse
mkdir my_safe_directory_replicator_reverse

docker run \
 --rm \
 --name temp_crdb \
 -v ./certs_replicator_reverse:/certs_replicator_reverse \
 -v ./my_safe_directory_replicator_reverse:/my_safe_directory_replicator_reverse \
 cockroachdb/cockroach:$COCKROACHDB_VERSION \
  cert create-ca \
   --certs-dir=/certs_replicator_reverse \
   --ca-key=/my_safe_directory_replicator_reverse/ca.key

echo
ls -l certs_replicator_reverse my_safe_directory_replicator_reverse
EOFHERE
)
do_stage "$TITLE" "$TEXT" "$CMD" '$COCKROACHDB_VERSION'

TEXT='Next step: Generate MOLT Replicator webhook TLS/endpoint certificate and private key'
CMD=$(cat <<'EOFHERE'
docker run \
 --rm \
 --name temp_crdb \
 -v ./certs_replicator_reverse:/certs_replicator_reverse \
 -v ./my_safe_directory_replicator_reverse:/my_safe_directory_replicator_reverse \
 cockroachdb/cockroach:$COCKROACHDB_VERSION \
  cert create-node \
   molt_replicator_host \
   --certs-dir=/certs_replicator_reverse \
   --ca-key=/my_safe_directory_replicator_reverse/ca.key 

echo
ls -l certs_replicator_reverse my_safe_directory_replicator_reverse
EOFHERE
)
do_stage '' "$TEXT" "$CMD" '$COCKROACHDB_VERSION'

TEXT='Now base64-encode and URL-encode the TLS/endpoint certificate and private key
and the CA certificate for use later in the CREATE CHANGEFEED statement.'
CMD=$(cat <<'EOFHERE'
NODE_CERT_BASE64_URL_ENCODED=$(b64_encode certs_replicator_reverse/node.crt | jq -R -r '@uri')
NODE_KEY_BASE64_URL_ENCODED=$(b64_encode certs_replicator_reverse/node.key | jq -R -r '@uri')
CA_CERT_BASE64_URL_ENCODED=$(b64_encode certs_replicator_reverse/ca.crt | jq -R -r '@uri')

echo
echo 'TLS/endpoint certificate base64-encoded and URL-encoded:'
echo
echo $NODE_CERT_BASE64_URL_ENCODED
echo 
echo 'TLS/endpoint key base64-encoded and URL-encoded:'
echo
echo $NODE_KEY_BASE64_URL_ENCODED
echo
echo 'CA certificate base64-encoded and URL-encoded:'
echo
echo $CA_CERT_BASE64_URL_ENCODED
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Enable rangefeeds for change data capture for reverse migration'
CMD=$(cat <<'EOFHERE'
docker exec roach-seattle-1 \
 ./cockroach --host=roach-seattle-1:26257 sql --certs-dir=certs --database chinook --format table -e \
  'SET CLUSTER SETTING kv.rangefeed.enabled = true'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TITLE='-- START DOWNTIME --'
TEXT='Stop MySQL application traffic.

Wait for replication pipeline to drain.
Wait at least as long as the MOLT Replicator --flushPeriod setting if specified,
or at least 30 seconds if not specified.

Check that replication pipeline has drained

Look at "upserted rows" lines in the MOLT Replicator log output'
CMD=$(cat <<'EOFHERE'
docker logs replicator_forward 2>&1 | grep 'upserted rows'
EOFHERE
)
do_stage "$TITLE" "$TEXT" "$CMD" noexpand

TEXT='Stop MOLT Replicator forward migration'
CMD=$(cat <<'EOFHERE'
docker stop replicator_forward
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

# NOTE: --disableAuthentication is used for this local demo only.
# In production, use JWT or TLS client cert authentication.
TEXT='Start MOLT Replicator for the reverse migration'
CMD=$(cat <<'EOFHERE'
docker run \
 -d \
 --name=replicator_reverse \
 --hostname=molt_replicator_host \
 --ip=172.27.0.104 \
 --net=us-west2-net \
 -p 30004:30004 \
 -v ./certs_cockroachdb_clients:/certs_crdb \
 -v ./certs_replicator_reverse:/certs_replicator_reverse \
 cockroachdb/replicator \
  start \
   -v \
   --stagingSchema _replicator \
   --bindAddr :30004 \
   --metricsAddr :30005 \
   --disableAuthentication \
   --targetConn "mysql://root:$MYSQL_ROOT_PASSWORD@mysql_host:3306/Chinook?sslmode=disable" \
   --stagingConn 'postgres://root@roach-seattle-1:26257/chinook?sslmode=verify-full&sslrootcert=certs_crdb%2Fca.crt&sslcert=certs_crdb%2Fclient.root.crt&sslkey=certs_crdb%2Fclient.root.key' \
   --tlsCertificate /certs_replicator_reverse/node.crt \
   --tlsPrivateKey /certs_replicator_reverse/node.key
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Look at MOLT Replicator logs'
CMD=$(cat <<'EOFHERE'
docker logs replicator_reverse
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Get the CockroachCB cluster logical timestamp for the changefeed cursor parameter'
CMD=$(cat <<'EOFHERE'
CLUSTER_LOGICAL_TIMESTAMP=$(docker exec roach-seattle-1 ./cockroach --host=roach-seattle-1:26257 sql --certs-dir=certs --database chinook --format csv -e 'SELECT cluster_logical_timestamp()' | tail -n -1)

echo "Cluster logical timestamp: $CLUSTER_LOGICAL_TIMESTAMP"
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Create changefeed to MOLT Replicator'
CMD=$(cat <<'EOFHERE'
docker exec roach-seattle-1 \
 ./cockroach --host=roach-seattle-1:26257 sql --certs-dir=certs --database chinook --format table -e \
  "CREATE CHANGEFEED FOR TABLE album, artist, customer, employee, genre, invoice, invoiceline, mediatype, playlist, playlisttrack, track
   INTO 'webhook-https://molt_replicator_host:30004/Chinook?client_cert=$NODE_CERT_BASE64_URL_ENCODED&client_key=$NODE_KEY_BASE64_URL_ENCODED&ca_cert=$CA_CERT_BASE64_URL_ENCODED' 
   WITH updated, 
        resolved = '250ms', 
        min_checkpoint_frequency = '250ms', 
        initial_scan = 'no', 
        cursor = '$CLUSTER_LOGICAL_TIMESTAMP', 
        webhook_sink_config = '{\"Flush\":{\"Bytes\":1048576,\"Frequency\":\"1s\"}}'"
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Reverse replication is set up

Show the changefeed job'
CMD=$(cat <<'EOFHERE'
docker exec roach-seattle-1 \
 ./cockroach --host=roach-seattle-1:26257 sql --certs-dir=certs --database chinook --format records \
  -e 'SHOW CHANGEFEED JOBS'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

echo
echo 'Switch application to start using CockroachDB'
echo 'Validate application'
echo 'Perform final go-no-go tests'
echo

TITLE='-- END DOWNTIME --'
TEXT='Migration is complete.

Show reverse replication is working

First show the number of playlists in MySQL and CockroachDB'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
  'SELECT count(*) AS playlist_count_mysql FROM Playlist'

echo  

docker exec roach-seattle-1 \
 ./cockroach --host=roach-seattle-1:26257 sql --certs-dir=certs --database chinook --format table -e \
  'SELECT count(*) AS playlist_count_cockroachdb FROM playlist'
EOFHERE
)
do_stage "$TITLE" "$TEXT" "$CMD" noexpand

TEXT='Insert a new playlist on CockroachDB'
CMD=$(cat <<'EOFHERE'
docker exec roach-seattle-1 \
 ./cockroach --host=roach-seattle-1:26257 sql --certs-dir=certs --database chinook --format table -e \
  "INSERT INTO PLAYLIST (playlistid, name) (
    WITH cte AS (
     SELECT max(playlistid) AS max_playlistid FROM playlist)
    SELECT cte.max_playlistid + 1 AS playlistid, 'AI-Generated Favorites' AS name
    FROM cte
   )"

echo "Sleep $REVERSE_REPLICATION_LATENCY_SLEEP seconds to let the change propagate to MySQL"
sleep $REVERSE_REPLICATION_LATENCY_SLEEP
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Again show the number of playlists in MySQL and CockroachDB'
CMD=$(cat <<'EOFHERE'
docker exec my-mysql-db \
 mysql --password=$MYSQL_ROOT_PASSWORD --database=Chinook --table -e \
  'SELECT count(*) AS playlist_count_mysql FROM Playlist'

echo

docker exec roach-seattle-1 \
 ./cockroach --host=roach-seattle-1:26257 sql --certs-dir=certs --database chinook --format table -e \
  'SELECT count(*) AS playlist_count_cockroachdb FROM playlist'
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Look at MOLT Replicator logs again'
CMD=$(cat <<'EOFHERE'
docker logs replicator_reverse
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TITLE='Decommission'
TEXT='After using CockroachDB long enough, when the customer is satisfied with the migration,
shut down reverse migration and shut down the original MySQL server

Stop the changefeed for MOLT Replicator for the reverse replication'
CMD=$(cat <<'EOFHERE'
docker exec roach-seattle-1 \
 ./cockroach --host=roach-seattle-1:26257 sql --certs-dir=certs --database chinook --format records -e \
  "CANCEL JOB (SELECT job_ID FROM [SHOW CHANGEFEED JOBS] WHERE status='running' ORDER BY created DESC LIMIT 1)"
EOFHERE
)
do_stage "$TITLE" "$TEXT" "$CMD" noexpand

TEXT='Stop MOLT Replicator reverse migration'
CMD=$(cat <<'EOFHERE'
docker stop replicator_reverse
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

TEXT='Stop MySQL'
CMD=$(cat <<'EOFHERE'
docker stop my-mysql-db
EOFHERE
)
do_stage '' "$TEXT" "$CMD" noexpand

echo
echo '-- End of script --'
