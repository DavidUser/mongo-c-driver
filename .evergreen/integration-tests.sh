#!/bin/sh
set -o xtrace   # Write all commands first to stderr
set -o errexit  # Exit the script with error if any of the commands fail

DIR=$(dirname $0)
# Functions to fetch MongoDB binaries
. $DIR/download-mongodb.sh

get_distro
GENERIC_LINUX_URL=$(get_mongodb_download_url_for "linux-x86_64" "$MONGODB_VERSION")
get_mongodb_download_url_for "$DISTRO" "$MONGODB_VERSION"
if [ "$MONGODB_DOWNLOAD_URL" = $GENERIC_LINUX_URL -a ! "$SSL" = "nossl" ]; then
   echo "Requested a version of MongoDB with SSL, but only generic (non-SSL) Linux version available"
   exit 1;
fi
DRIVERS_TOOLS=./ download_and_extract "$MONGODB_DOWNLOAD_URL" "$EXTRACT"


OS=$(uname -s | tr '[:upper:]' '[:lower:]')

AUTH=${AUTH:-noauth}
SSL=${SSL:-nossl}
TOPOLOGY=${TOPOLOGY:-server}

case "$OS" in
   cygwin*)
      export MONGO_ORCHESTRATION_HOME="c:/data/MO"
      ;;
   *)
      export MONGO_ORCHESTRATION_HOME=$(pwd)"/MO"
      ;;
esac
rm -rf $MONGO_ORCHESTRATION_HOME
mkdir -p $MONGO_ORCHESTRATION_HOME/lib
mkdir -p $MONGO_ORCHESTRATION_HOME/db

if [ "$AUTH" = "auth" ]; then
  if [ -z $ORCHESTRATION_FILE ]; then
    ORCHESTRATION_FILE="auth"
  fi
  MONGO_SHELL_CONNECTION_FLAGS="-ubob -ppwd123"
fi

if [ "$IPV4_ONLY" = "on" ]; then
  ORCHESTRATION_FILE="${ORCHESTRATION_FILE}-ipv4-only"
fi

if [ ! -z "$AUTHSOURCE" ]; then
   ORCHESTRATION_FILE="${ORCHESTRATION_FILE}-${AUTHSOURCE}"
   MONGO_SHELL_CONNECTION_FLAGS="${MONGO_SHELL_CONNECTION_FLAGS} --authenticationDatabase ${AUTHSOURCE}"
fi

if [ -z $ORCHESTRATION_FILE ]; then
   ORCHESTRATION_FILE="basic"
fi

if [ "$SSL" != "nossl" ]; then
   cp -f src/libmongoc/tests/x509gen/* $MONGO_ORCHESTRATION_HOME/lib/
   # find print0 and xargs -0 not available on Solaris. Lets hope for good paths
   find orchestration_configs -name \*.json | xargs perl -p -i -e "s|/tmp/orchestration-home|$MONGO_ORCHESTRATION_HOME/lib|g"
   ORCHESTRATION_FILE="${ORCHESTRATION_FILE}-ssl"
fi

export ORCHESTRATION_FILE="orchestration_configs/${TOPOLOGY}s/${ORCHESTRATION_FILE}.json"
export ORCHESTRATION_URL="http://localhost:8889/v1/${TOPOLOGY}s"

export TMPDIR=$MONGO_ORCHESTRATION_HOME/db
echo From shell `date` > $MONGO_ORCHESTRATION_HOME/server.log


case "$OS" in
   cygwin*)
      # Python has problems with unix style paths in cygwin. Must use c:\\ paths
      rm -rf /cygdrive/c/mongodb
      cp -r mongodb /cygdrive/c/mongodb
      echo "{ \"releases\": { \"default\": \"c:\\\\mongodb\\\\bin\" }}" > orchestration.config

      # Make sure MO is running latest version
      python.exe -m virtualenv venv
      cd venv
      . Scripts/activate
      rm -rf mongo-orchestration
      git clone --depth 1 git@github.com:10gen/mongo-orchestration.git
      cd mongo-orchestration
      pip install .
      cd ../..
      ls `pwd`/mongodb/bin/mongo* || true
      nohup mongo-orchestration -f orchestration.config -e default --socket-timeout-ms=60000 --bind=127.0.0.1  --enable-majority-read-concern -s wsgiref start > $MONGO_ORCHESTRATION_HOME/out.log 2> $MONGO_ORCHESTRATION_HOME/err.log < /dev/null &
      if [ "$SSL" != "nossl" ]; then
         export MONGO_SHELL_CONNECTION_FLAGS="$MONGO_SHELL_CONNECTION_FLAGS --host localhost --ssl --sslCAFile=$MONGO_ORCHESTRATION_HOME/lib/ca.pem --sslPEMKeyFile=$MONGO_ORCHESTRATION_HOME/lib/client.pem"
      fi
      ;;
   *)
      echo "{ \"releases\": { \"default\": \"`pwd`/mongodb/bin\" } }" > orchestration.config
      if [ -f /opt/python/2.7/bin/python ]; then
         # Python toolchain installation.
         PYTHON=/opt/python/2.7/bin/python
      else
         PYTHON=python
      fi

      PYTHON_MAJ=$(python -c 'import sys; print (sys.version_info[0])')
      PYTHON_MIN=$(python -c 'import sys; print (sys.version_info[1])')
      if [ "$PYTHON_MAJ" -ge "3" -a "$PYTHON_MIN" -ge "8" ]; then
         # mongo-orchestration currently does not run with python 3.8 per PYTHON-2067. Explicitly use python 2.
         PYTHON=python2
      fi

      $PYTHON -m virtualenv venv
      cd venv
      . bin/activate
      rm -rf mongo-orchestration
      # Make sure MO is running latest version
      git clone --depth 1 git@github.com:10gen/mongo-orchestration.git
      cd mongo-orchestration
      # Our zSeries machines are static-provisioned, cache corruptions persist.
      if [ $(uname -m) = "s390x" ]; then
         echo "Disabling pip cache"
         PIP_PARAM="--no-cache-dir"
      fi
      pip $PIP_PARAM install .
      cd ../..
      mongo-orchestration -f orchestration.config -e default --socket-timeout-ms=60000 --bind=127.0.0.1  --enable-majority-read-concern start > $MONGO_ORCHESTRATION_HOME/out.log 2> $MONGO_ORCHESTRATION_HOME/err.log < /dev/null &
      if [ "$SSL" != "nossl" ]; then
         export MONGO_SHELL_CONNECTION_FLAGS="$MONGO_SHELL_CONNECTION_FLAGS --host localhost --ssl --sslCAFile=$MONGO_ORCHESTRATION_HOME/lib/ca.pem --sslPEMKeyFile=$MONGO_ORCHESTRATION_HOME/lib/client.pem"
      fi
      ;;
esac

sleep 15
curl http://localhost:8889/ -sS --max-time 120 --fail

sleep 5

pwd
curl -sS --data @"$ORCHESTRATION_FILE" "$ORCHESTRATION_URL" --max-time 300 --fail

sleep 15

`pwd`/mongodb/bin/mongo $MONGO_SHELL_CONNECTION_FLAGS --eval 'printjson(db.serverBuildInfo())' admin
`pwd`/mongodb/bin/mongo $MONGO_SHELL_CONNECTION_FLAGS --eval 'printjson(db.isMaster())' admin
