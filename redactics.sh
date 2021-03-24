#!/bin/bash

COMMAND=$1

usage()
{
  printf '%s\n' "Redactics CLI"
  printf 'Usage: %s [-h|--help] <first> <second> [<third>]\n' "$0"
  printf '\t%s\n' "<first>: The first argument"
  printf '\t%s\n' "<second>: The second argument"
  printf '\t%s\n' "<third>: The second argument with a default (default: 'third - default')"
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

BASE_PATH=~/.redactics
VALUES_PATH=${BASE_PATH}/values.yaml
EXPORT_POD_PREFIX=redactics-export-
NAMESPACE=`helm ls --all-namespaces | grep redactics | awk '{print $2}'`

function check_pod {
  echo "*** WAITING FOR REDACTICS-EXPORT POD TO BE PLACED IN \"$NAMESPACE\" NAMESPACE ***"
  EXPORT_POD=`kubectl -n $NAMESPACE get pods | grep $EXPORT_POD_PREFIX | grep Running | grep 1/1 | awk '{print $1}'`
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

case "$1" in

list-exports)
  place_export_pod
  exports=`kubectl -n $NAMESPACE exec $EXPORT_POD -- ls /redacticsdata/export`
  printf "\n--- EXPORTS -----------------\n\n$exports\n\n-----------------------------\n"
  cleanup
  ;;

download-export)
  DOWNLOAD=$2
  place_export_pod
  echo "*** DOWNLOADING $DOWNLOAD ***"
  kubectl -n $NAMESPACE cp ${EXPORT_POD}:redacticsdata/export/$DOWNLOAD $DOWNLOAD || cleanup
  cleanup
  ;;

list-jobs)
  DATABASE=$2
  # error handling if database UUID is missing
  ps=`kubectl -n $NAMESPACE get pods | grep redactics-scheduler | grep Running | grep 1/1 | awk '{print $1}'`
  kubectl -n $NAMESPACE exec $ps -- /entrypoint.sh airflow list_dag_runs $DATABASE | grep -A 31 "id  | run_id"
  ;;

start-job)
  DATABASE=$2
  # error handling if database UUID is missing
  ps=`kubectl -n $NAMESPACE get pods | grep redactics-scheduler | grep Running | grep 1/1 | awk '{print $1}'`
  kubectl -n $NAMESPACE exec $ps -- /entrypoint.sh airflow trigger_dag $DATABASE
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
