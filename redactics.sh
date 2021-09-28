#!/bin/bash

COMMAND=$1

usage()
{
  printf 'Usage: %s [-h|--help] <command>\n' "$0"
  printf '\t%s\n' "possible commands:"
  printf '\t\t%s\n' "list-exports (lists all exported files)"
  printf '\t\t%s\n' "download-export [filename] (downloads [filename] to local directory)"
  printf '\t\t%s\n' "list-jobs [database ID] (lists all export steps for provided [database ID])"
  printf '\t\t%s\n' "start-job [database ID] (starts new export job for provided [database ID])"
  printf '\t\t%s\n' "start-scan [database ID] (starts new PII scan for provided [database ID])"
  printf '\t\t%s\n' "forget-user [database ID] [email] (creates user removal SQL queries for provided [database ID] and [email] address and downloads file to local directory)"
  printf '\t\t%s\n' "install-sample-table [database ID] [sample table] (installs a collection of sample tables using the authentication info provided for [database ID]. [Sample table] options include: olympics, marketing_campaign)"
  printf '\t\t%s\n' "version (outputs CLI version)"
  printf '\t%s\n' "-h, --help: Prints help"
}

POD=$(cat << EOF
apiVersion: v1
kind: Pod
metadata:
  generateName: redactics-export-
  labels:
    app: redactics-export
spec:
  volumes:
    - name: redacticsdata
      persistentVolumeClaim:
        claimName: redactics-dumpvol
  containers:
    - name: export
      image: debian:buster-slim
      command: ["sleep", "infinity"]
      volumeMounts:
        - mountPath: "/redacticsdata"
          name: redacticsdata
EOF
)

EXPORT_POD_PREFIX=redactics-export-
NAMESPACE=$(helm ls --all-namespaces | grep redactics | awk '{print $2}' | grep redactics)
REDACTICS_SCHEDULER=
VERSION=1.4.0
KUBECTL=$(which kubectl)
HELM=$(which helm)

function check_pod {
  echo "*** WAITING FOR REDACTICS-EXPORT POD TO BE PLACED IN \"$NAMESPACE\" NAMESPACE ***"
  EXPORT_POD=$(kubectl -n $NAMESPACE get pods | grep $EXPORT_POD_PREFIX | grep Running | grep 1/1 | awk '{print $1}')
}

function cleanup {
  echo "*** CLEANING UP ***"
  kubectl -n $NAMESPACE --wait=false delete pod -l app=redactics-export
}

function place_export_pod {
  echo "$POD" | kubectl -n $NAMESPACE create -f -

  # wait for pod to be placed
  # TODO: give up and cleanup
  check_pod
  while [ -z "$EXPORT_POD" ]
  do
    sleep 1
    check_pod
  done
}

function get_redactics_scheduler {
  REDACTICS_SCHEDULER=$(kubectl -n $NAMESPACE get pods | grep redactics-scheduler | grep Running | grep 1/1 | awk '{print $1}') 
}

# generate warnings about missing helm and kubectl commands
if [[ -z "$KUBECTL" ]]; then
  printf "ERROR: kubectl command missing from your shell path. The Redactics CLI requires your kubectl command be accessible\n"
  exit 1
elif [[ -z "$HELM" ]]; then
  printf "ERROR: helm command missing from your shell path. The Redactics CLI requires the helm command to determine which Kubernetes namespace hosts your Redactics Agent\n"
  exit 1
elif [[ -z "$NAMESPACE" ]]; then
  printf "ERROR: Redactics does not appeared to be installed on the Kubernetes cluster you are currently authenticated to. Please re-install Redactics using the command provided within the \"Agents\" section of your Redactics account\n"
  exit 1
fi

case "$1" in

list-exports)
  place_export_pod
  exports=$(kubectl -n $NAMESPACE exec $EXPORT_POD -- ls /redacticsdata/export)
  printf "\n--- EXPORTS -----------------\n\n$exports\n\n-----------------------------\n"
  cleanup
  ;;

download-export)
  DOWNLOAD=$2
  if [ -z $DOWNLOAD ]
  then
    usage
    exit 1
  fi
  place_export_pod
  echo "*** DOWNLOADING $DOWNLOAD ***"
  kubectl -n $NAMESPACE cp ${EXPORT_POD}:redacticsdata/export/$DOWNLOAD $DOWNLOAD || cleanup
  cleanup
  ;;

list-jobs)
  DAG=$2
  if [ -z $DAG ]
  then
    usage
    exit 1
  fi
  get_redactics_scheduler
  kubectl -n $NAMESPACE -c agent-scheduler exec $REDACTICS_SCHEDULER -- bash -c "/entrypoint.sh airflow list_dag_runs $DAG | grep -A 31 \"id  | run_id\""
  ;;

start-job)
  DATABASE=$2
  if [ -z $DATABASE ]
  then
    usage
    exit 1
  fi
  get_redactics_scheduler
  kubectl -n $NAMESPACE -c agent-scheduler exec $REDACTICS_SCHEDULER -- bash -c "/entrypoint.sh airflow trigger_dag $DATABASE"
  if [ $? == 0 ]
  then
    printf "YOUR JOB HAS BEEN QUEUED!\n\nTo track progress, enter \"redactics list-jobs ${DATABASE}\". Errors will be reported to your Redactics account (https://app.redactics.com).\n"
  fi
  ;;

start-scan)
  DATABASE=$2
  if [ -z $DATABASE ]
  then
    usage
    exit 1
  fi
  get_redactics_scheduler
  kubectl -n $NAMESPACE -c agent-scheduler exec $REDACTICS_SCHEDULER -- bash -c "/entrypoint.sh airflow trigger_dag ${DATABASE}-scanner"
  if [ $? == 0 ]
  then
    printf "YOUR SCAN HAS BEEN QUEUED!\n\nTo track progress, enter \"redactics list-jobs ${DATABASE}-scanner\". Both the results and any errors will be reported to your Redactics account (https://app.redactics.com/usecases/piiscanner).\n"
  fi
  ;;

forget-user)
  DATABASE=$2
  EMAIL=$3
  if [ -z $DATABASE ] || [ -z $EMAIL ]
  then
    usage
    exit 1
  fi
  get_redactics_scheduler
  JSON="'{\"email\": \"${EMAIL}\"}'"
  kubectl -n $NAMESPACE -c agent-scheduler exec $REDACTICS_SCHEDULER -- bash -c "/entrypoint.sh airflow trigger_dag -c $JSON ${DATABASE}-usersearch"
  if [ $? == 0 ]
  then
    poll="running"
    until [ $poll = "success" ] || [ $poll = "failed" ]
    do
      printf "WAITING FOR JOB COMPLETION...\n"
      last_run=$(kubectl -n $NAMESPACE -c agent-scheduler exec $REDACTICS_SCHEDULER -- bash -c "/entrypoint.sh airflow list_dag_runs ${DATABASE}-usersearch | grep -A 2 \"id  | run_id\" | tail -n 1")
      poll=$(echo $last_run | awk '{print $5}')
      sleep 3
    done

    if [ $poll = "success" ]
    then
      DOWNLOAD="forgetuser-queries-${EMAIL}.sql"
      place_export_pod
      echo "*** DOWNLOADING $DOWNLOAD ***"
      kubectl -n $NAMESPACE cp ${EXPORT_POD}:redacticsdata/export/$DOWNLOAD $DOWNLOAD || cleanup
    else
      printf "ERROR: there has been a problem with this request. Please check your Redactics account for more information (https://app.redactics.com)."
    fi
  fi
  ;;

install-sample-table)
  DATABASE=$2
  SAMPLE_TABLE=$3
  if [ -z $DATABASE ] || [ -z $SAMPLE_TABLE ]
  then
    usage
    exit 1
  fi
  if [ $SAMPLE_TABLE != "olympics" ] && [ $SAMPLE_TABLE != "marketing_campaign" ]
  then
    printf "sample table needs to be one of \"olympics\" or \"marketing_campaign\"\n"
    exit 1
  fi
  # confirm table creation
  printf "This command will install the tables \"$SAMPLE_TABLE\" into the database provided within your Helm config file corresponding to connection ID $DATABASE\n(check your Redactics account to determine the path where this file is installed on your workstation, it is usually ~/.redactics/values.yaml).\nBefore installation this command will drop any existing tables called \"$SAMPLE_TABLE\", so if you happen to have a table you have created yourself with this same name, you'll want to try installing another sample database.\n\nEnter \"yes\" to confirm installation of this table\n\n"
  read -r confirm
  if [ $confirm != "yes" ]
  then
    exit 0
  fi
  get_redactics_scheduler
  kubectl -n $NAMESPACE -c agent-scheduler exec $REDACTICS_SCHEDULER -- bash -c "/entrypoint.sh airflow trigger_dag ${DATABASE}-sampletable-${SAMPLE_TABLE}"
  if [ $? == 0 ]
  then
    printf "YOUR TABLE INSTALLATION HAS BEEN QUEUED!\n\nTo track progress, enter \"redactics list-jobs ${DATABASE}-sampletable-${SAMPLE_TABLE}\". Both the results and any errors will be reported to your Redactics account.\n"
  fi
  ;;

version)
  printf "$VERSION (visit https://app.redactics.com/cli to check on version updates)\n"
  ;;

-h|--help)
  usage
  exit 0
  ;;
*)
  usage
  exit 0
  ;;
esac
