#!/bin/bash

############################################################################
# Copyright Nash!Com, Daniel Nashed 2019, 2020 - APACHE 2.0 see LICENSE
# Copyright IBM Corporation 2015, 2019 - APACHE 2.0 see LICENSE
############################################################################

# This script is the main entry point for Docker container and used instead of rc_domino.
# You can still interact with the start script invoking rc_domino which is Docker aware.
# This entry point is invoked by Docker to start the Domino server and also acts as a shutdown monitor.

export DOMDOCK_DIR=/domino-docker
export DOMDOCK_LOG_DIR=/domino-docker
export DOMDOCK_TXT_DIR=/domino-docker
export DOMDOCK_SCRIPT_DIR=/domino-docker/scripts


if [ -z "$LOTUS" ]; then
  if [ -x /opt/hcl/domino/bin/server ]; then
    export LOTUS=/opt/hcl/domino
  else
    export LOTUS=/opt/ibm/domino
  fi
fi

# export required environment variables
export Notes_ExecDirectory=$LOTUS/notes/latest/linux
export DOMINO_DATA_PATH=/local/notesdata

DOMINO_SERVER_ID=$DOMINO_DATA_PATH/server.id
DOMINO_DOCKER_CFG_SCRIPT=$DOMDOCK_SCRIPT_DIR/docker_prestart.sh
DOMINO_START_SCRIPT=/opt/nashcom/startscript/rc_domino_script

# always use whoami
LOGNAME=`whoami 2>/dev/null`

# check current UID - only reliable source
CURRENT_UID=`id -u`

if [ "$CURRENT_UID" = "0" ]; then
  # if running as root set user to "notes"
  DOMINO_USER="notes"
else
  
  if [ ! "$LOGNAME" = "notes" ]; then

    if [ -z "$LOGNAME" ]; then
      # if the uid/user is not in /etc/passwd, update notes entry --> empty if uid cannot be mapped
      $DOMDOCK_SCRIPT_DIR/nuid2pw $CURRENT_UID
      LOGNAME=notes
    else
      if [ ! -z "$DOCKER_UID_NOTES_MAP_FORCE" ]; then
        # if the uid/user is not in /etc/passwd, update notes entry and remove numeric entry for UID if present
        $DOMDOCK_SCRIPT_DIR/nuid2pw $CURRENT_UID
        LOGNAME=notes
      fi
    fi
  fi

  DOMINO_USER=$LOGNAME
fi

DOMINO_GROUP=`id -gn`

export LOGNAME
export DOMINO_USER
export DOMINO_GROUP

# set more paranoid umask to ensure files can be only read by user
umask 0077


run_external_script ()
{
  if [ -z "$1" ]; then
    return 0
  fi

  SCRIPT2RUN=$DOMDOCK_SCRIPT_DIR/$1

  if [ ! -e "$SCRIPT2RUN" ]; then
    return 0
  fi

  if [ ! -x "$SCRIPT2RUN" ]; then
    echo "Cannot execute script " [$SCRIPT2RUN]
    return 0
  fi

  if [ ! -z "$EXECUTE_SCRIPT_CHECK_OWNER" ]; then
    SCRIPT_OWNER=`stat -c %U $SCRIPT2RUN`
    if [ ! "$SCRIPT_OWNER" = "$EXECUTE_SCRIPT_CHECK_OWNER" ]; then
      echo "Wrong owner for script -- not executing" [$SCRIPT2RUN]
      return 0
    fi
  fi

  echo "--- [$1] ---" 
  $SCRIPT2RUN
  echo "--- [$1] ---" 

  return 0
}

stop_server ()
{
  echo "--- Stopping Domino Server ---"

  run_external_script before_shutdown.sh

  if [ "$LOGNAME" = "$DOMINO_USER" ] ; then
    $DOMINO_START_SCRIPT stop
  else
    su - notes -c "$DOMINO_START_SCRIPT stop"
  fi

  echo "--- Domino Server Shutdown ---"

  run_external_script after_shutdown.sh

  exit 0
}

# "docker stop" will send a SIGTERM to the shell. catch it and stop Domino gracefully.
# Ensure to use e.g. "docker stop --time=90 .." to ensure server has sufficient time to terminate.

trap "stop_server" 1 2 3 4 6 9 13 15 17 19 23


run_external_script before_data_copy.sh

# Data Update Operations
if [ "$LOGNAME" = "$DOMINO_USER" ] ; then
  $DOMDOCK_SCRIPT_DIR/domino_install_data_copy.sh
else
  su - notes -c $DOMDOCK_SCRIPT_DIR/domino_install_data_copy.sh
fi

run_external_script before_config_script.sh

# Check if server is configured. Else start custom configuration script
if [ -z `grep -i "ServerSetup=" $DOMINO_DATA_PATH/notes.ini` ]; then
  if [ ! -z "$DOMINO_DOCKER_CFG_SCRIPT" ]; then
    if [ -x "$DOMINO_DOCKER_CFG_SCRIPT" ]; then
      if [ "$LOGNAME" = "$DOMINO_USER" ] ; then
        $DOMINO_DOCKER_CFG_SCRIPT
      else
        su - $DOMINO_USER -c "$DOMINO_DOCKER_CFG_SCRIPT"
      fi
    fi
  fi
fi 

run_external_script after_config_script.sh

# Check if server is configured. Else start remote configuation on port 1352
if [ -z `grep -i "ServerSetup=" $DOMINO_DATA_PATH/notes.ini` ]; then

  echo "Configuration for automated setup not found."
  echo "Starting Domino Server in listen mode"

  echo "--- Configuring Domino Server ---"

  if [ "$LOGNAME" = "$DOMINO_USER" ] ; then
    cd $DOMINO_DATA_PATH
    $LOTUS/bin/server -listen 1352
  else
    su - $DOMINO_USER -c "cd $DOMINO_DATA_PATH; $LOTUS/bin/server -listen 1352"
  fi

  echo "--- Configuration ended ---"
  echo
fi

run_external_script before_server_start.sh

# Finally start server

echo "--- Starting Domino Server ---"

echo "LOGNAME: [$LOGNAME]"

if [ "$LOGNAME" = "$DOMINO_USER" ] ; then
  $DOMINO_START_SCRIPT start
else
  su - $DOMINO_USER -c "$DOMINO_START_SCRIPT start"
fi

# Wait for shutdown signal. This loop should never terminate, because it would 
# shutdown the Docker container immediately and kill Domino.

while true
do
  sleep 1
done

exit 0

