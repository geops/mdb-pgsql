#!/bin/bash
#
# This script converts Microsoft Access 2000 MDB databases to postgresql SQL files
# without needing an installation of Microsoft Access itself.
#
# The hard work is done by the excellent mdb-sqlite.
# This script just uses the sqlite database to generate to posgresql insert from it
#
# Accordingly you need to install and build mdb-sqlite. The program can be downloaded
# at http://code.google.com/p/mdb-sqlite/
# See the build instructions there to build the JAR file.
#
# Usage
# -----
#
# Before using mdb-ppgsql the environment variable MDB_SQLITE_JAR with the
# path to the mdb-sqlite jar has to be set. Example:
#   export MDB_SQLITE_JAR=/home/myself/jars/mdb-sqlite.jar
#
# After that the script can be used like
#
#   mdb-pgsql.sh <mdb file> [<target schema>]
#
# The <target schema> parameter is optional. If not set, the schema
# "pubilc" will be used.
#
# The generated SQL will be written to the standard output. It is recommended
# to pipe it to a file.
#
#
# This script depends on
# ----------------------
#
# - Java
# - The mdb-sqlite Jar
# - sqlite3 command line tool
# - various Unix tools like sed, tr, cat and grep

set -e

TMPDIR=/tmp
TMPSQL="$TMPDIR/tmp.sql"

MDB_SQLITE_JAR=${MDB_SQLITE_JAR}

# target schema for import
SCHEMA_NAME=$2
if [ -z "$SCHEMA_NAME" ]; then
  # default to public
  SCHEMA_NAME="public"
fi

function usage_info {
    echo "Usage: $0 <mdb database file> [<target schema>]"
    echo "   The SQL will be written to stdout"
    echo ""
    echo "This script depends on mdb-sqlite. Please set"
    echo "the environment variable MDB_SQLITE_JAR"
}

function mdb_to_sqlite {
    if [ -z "$MDB_SQLITE_JAR" ]; then
        echo "The MDB_SQLITE_JAR environment variable MDB_SQLITE_JAR is not set." 1>&2
        echo "Can not procced" 1>&2
        exit 1
    fi
    
    java -jar "$MDB_SQLITE_JAR" "$1" "$2"
}

function sqlite_to_pgsql {
    sqlite3 $1 '.dump' >$TMPSQL

    echo "begin;"
    echo "set search_path to $SCHEMA_NAME;"
    echo "set standard_conforming_strings=on;"

    # create a casts to cast ints/bigints to timestamp
    cat <<EOF
create or replace function sqlite3_datetime(bigint) returns timestamp without time zone as \$\$
select (TIMESTAMP WITH TIME ZONE 'epoch ' + \$1/1000 * INTERVAL '1 second')::timestamp without time zone;
\$\$ language sql;
create or replace function sqlite3_datetime(integer) returns timestamp without time zone as \$\$
select (TIMESTAMP WITH TIME ZONE 'epoch ' + \$1/1000 * INTERVAL '1 second')::timestamp without time zone;
\$\$ language sql;


CREATE CAST (bigint AS timestamp without time zone) WITH FUNCTION sqlite3_datetime(bigint) AS ASSIGNMENT;
CREATE CAST (integer AS timestamp without time zone) WITH FUNCTION sqlite3_datetime(integer) AS ASSIGNMENT;
EOF

    # create tables
    grep -e "^CREATE TABLE" $TMPSQL | \
      tr "'" "\"" | \
      sed 's/DOUBLE/double precision/g' | \
      sed 's/BLOB/bytea/g' | \
      sed 's/DATETIME/timestamp without time zone/g' | \
      sed 's/-/_/g' | \
      sed -r 's/^CREATE TABLE[\ ]+([A-Za-z_0-9].[A-Za-z_0-9\s ]+[A-Za-z_0-9].)[\s ]*\(/CREATE TABLE \"\1\" (/g' | \
      sed -r 's/\s+\"\s+\(/\" \(/g' | \
      sed -r "s/CREATE TABLE[\ ]+([A-Z_a-z\"0-9]+)/CREATE TABLE $SCHEMA_NAME.\1/g" | \
      tr "[A-Z]" "[a-z]"

    # data
    grep -v -e "^CREATE" $TMPSQL | \
      grep -v -e "^PRAGMA" | \
      grep -v -e "^BEGIN" | \
      grep -v -e "^COMMIT" | \
      sed -r "s/INSERT INTO \"([A-Za-z_0-9]+)\"/INSERT INTO $SCHEMA_NAME.\"\L\1\"/g"

    # remove the casts again
    cat <<EOF
DROP CAST (bigint AS timestamp without time zone) CASCADE;
DROP CAST (integer AS timestamp without time zone) CASCADE;
drop function if exists sqlite3_datetime(bigint);
drop function if exists sqlite3_datetime(integer);

EOF

    echo "commit;"

    rm -f $TMPSQL
}

if [ "$1" == "--help" ]; then
    usage_info
    exit 0
fi

if [ ! -f "$1" ]; then
    echo "The file $1 does not exist" 1>&2
    echo "" 1>&2
    usage_info
    exit 1
fi


DB_NAME="$( basename "$1" )"
DB_FULLNAME="$TMPDIR/$DB_NAME.sqlite3"

mdb_to_sqlite "$1" "$DB_FULLNAME"
sqlite_to_pgsql "$DB_FULLNAME"

rm -f "$DB_FULLNAME"
