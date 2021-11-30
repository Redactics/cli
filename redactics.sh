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
  printf '\t\t%s\n' "output-diagostics (creates a folder called \"redactics-diagnostics\" containing files useful for Redactics support to assist customers with troubleshooting agent issues. This excludes sensitive information such as your Helm config file or the contents of your Kubernetes secrets)"
  printf '\t\t%s\n' "version (outputs CLI version)"
  printf '\t%s\n' "-h, --help: Prints help"
}

NAMESPACE=$(helm ls --all-namespaces | grep redactics | awk '{print $2}' | grep redactics)
REDACTICS_SCHEDULER=
REDACTICS_HTTP_NAS=
VERSION=1.6.0
KUBECTL=$(which kubectl)
HELM=$(which helm)

function get_redactics_scheduler {
  REDACTICS_SCHEDULER=$($KUBECTL -n $NAMESPACE get pods | grep redactics-scheduler | grep Running | grep 1/1 | awk '{print $1}')
  if [[ -z "$REDACTICS_SCHEDULER" ]]; then
    printf "ERROR: the redactics scheduler pod cannot be found in the \"${NAMESPACE}\" Kubernetes namespace, or else it is not in a \"Running\" state ready to receive commands.\nTo correct this problem, if this pod is missing from your \"kubectl get pods -n ${NAMESPACE}\" output try reinstalling the Redactics agent.\nIf it is installed but not marked as running, please check for errors in the notification center (i.e. the notification bell) at https://app.redactics.com\nor else contact Redactics support for help (support@redactics.com)\n"
    exit 1
  fi
}

function get_redactics_http_nas {
  REDACTICS_HTTP_NAS=$($KUBECTL -n $NAMESPACE get pods | grep redactics-http-nas | grep Running | grep 1/1 | awk '{print $1}')
  if [[ -z "$REDACTICS_HTTP_NAS" ]]; then
    printf "ERROR: the redactics http nas pod cannot be found in the \"${NAMESPACE}\" Kubernetes namespace, or else it is not in a \"Running\" state ready to receive commands.\nTo correct this problem, if this pod is missing from your \"kubectl get pods -n ${NAMESPACE}\" output try reinstalling the Redactics agent.\nIf it is installed but not marked as running, please check for errors in the notification center (i.e. the notification bell) at https://app.redactics.com\nor else contact Redactics support for help (support@redactics.com)\n"
    exit 1
  fi
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
  DATABASE=$2
  if [ -z $DATABASE ]
  then
    usage
    exit 1
  fi
  get_redactics_http_nas
  $KUBECTL -n $NAMESPACE exec -it $REDACTICS_HTTP_NAS -- curl "http://localhost:3000/file/${DATABASE}"
  ;;

download-export)
  DATABASE=$2
  DOWNLOAD=$3
  if [ -z $DATABASE ] || [ -z $DOWNLOAD ]
  then
    usage
    exit 1
  fi
  get_redactics_http_nas
  $KUBECTL -n $NAMESPACE cp ${REDACTICS_HTTP_NAS}:/mnt/storage/${DATABASE}/${DOWNLOAD} $DOWNLOAD
  printf "${DOWNLOAD} HAS BEEN DOWNLOADED TO YOUR LOCAL DIRECTORY\n"
  ;;

list-jobs)
  DAG=$2
  if [ -z $DAG ]
  then
    usage
    exit 1
  fi
  get_redactics_scheduler
  $KUBECTL -n $NAMESPACE -c agent-scheduler exec $REDACTICS_SCHEDULER -- bash -c "/entrypoint.sh airflow list_dag_runs $DAG | grep -A 31 \"id  | run_id\""
  ;;

start-job)
  DATABASE=$2
  if [ -z $DATABASE ]
  then
    usage
    exit 1
  fi
  get_redactics_scheduler
  $KUBECTL -n $NAMESPACE -c agent-scheduler exec $REDACTICS_SCHEDULER -- bash -c "/entrypoint.sh airflow trigger_dag $DATABASE"
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
  $KUBECTL -n $NAMESPACE -c agent-scheduler exec $REDACTICS_SCHEDULER -- bash -c "/entrypoint.sh airflow trigger_dag ${DATABASE}-scanner"
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
  get_redactics_http_nas
  JSON="'{\"email\": \"${EMAIL}\"}'"
  $KUBECTL -n $NAMESPACE -c agent-scheduler exec $REDACTICS_SCHEDULER -- bash -c "/entrypoint.sh airflow trigger_dag -c $JSON ${DATABASE}-usersearch"
  if [ $? == 0 ]
  then
    poll="running"
    until [ $poll = "success" ] || [ $poll = "failed" ]
    do
      printf "WAITING FOR JOB COMPLETION...\n"
      last_run=$($KUBECTL -n $NAMESPACE -c agent-scheduler exec $REDACTICS_SCHEDULER -- bash -c "/entrypoint.sh airflow list_dag_runs ${DATABASE}-usersearch | grep -A 2 \"id  | run_id\" | tail -n 1")
      poll=$(echo $last_run | awk '{print $5}')
      sleep 3
    done

    if [ $poll = "success" ]
    then
      DOWNLOAD="forgetuser-queries-${EMAIL}.sql"
      echo "*** DOWNLOADING $DOWNLOAD ***"
      $KUBECTL -n $NAMESPACE cp ${REDACTICS_HTTP_NAS}:/mnt/storage/${DATABASE}/${DOWNLOAD} $DOWNLOAD
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
  $KUBECTL -n $NAMESPACE -c agent-scheduler exec $REDACTICS_SCHEDULER -- bash -c "/entrypoint.sh airflow trigger_dag ${DATABASE}-sampletable-${SAMPLE_TABLE}"
  if [ $? == 0 ]
  then
    printf "YOUR TABLE INSTALLATION HAS BEEN QUEUED!\n\nTo track progress, enter \"redactics list-jobs ${DATABASE}-sampletable-${SAMPLE_TABLE}\". Both the results and any errors will be reported to your Redactics account.\n"
  fi
  ;;

output-diagnostics)
  get_redactics_scheduler
  OUTPUT_FOLDER=redactics-diagnostics
  rm -rf $OUTPUT_FOLDER || true
  mkdir $OUTPUT_FOLDER
  localenv=$'KUBECTL: '
  localenv+=$($KUBECTL version)
  localenv+=$'\nHELM: '
  localenv+=$($HELM version)
  localenv+=$'\nREDACTICS CLI VERSION: '
  localenv+=$(echo $VERSION)
  localenv+=$'\nDETECTED KUBERNETES NAMESPACE: '
  localenv+=$(echo $NAMESPACE)
  localenv+=$'\nSCHEDULER POD: '
  localenv+=$(echo $REDACTICS_SCHEDULER)
  printf "$localenv" > ${OUTPUT_FOLDER}/env.log
  $HELM ls --all-namespaces > ${OUTPUT_FOLDER}/helm.log
  $KUBECTL -n $NAMESPACE get pods > ${OUTPUT_FOLDER}/pods.log
  $KUBECTL -n $NAMESPACE get pv > ${OUTPUT_FOLDER}/pv.log
  $KUBECTL -n $NAMESPACE get pvc > ${OUTPUT_FOLDER}/pvc.log
  $KUBECTL -n $NAMESPACE get secret > ${OUTPUT_FOLDER}/secret-listing.log
  $KUBECTL -n $NAMESPACE logs -l app.kubernetes.io/name=http-nas --tail=-1 > ${OUTPUT_FOLDER}/http-nas.log
  $KUBECTL -n $NAMESPACE logs -l component=scheduler --tail=-1 > ${OUTPUT_FOLDER}/scheduler.log
  $KUBECTL -n $NAMESPACE -c agent-scheduler cp $REDACTICS_SCHEDULER:/usr/local/airflow/logs ${OUTPUT_FOLDER}/airflow-logs
  printf "A folder called \"$OUTPUT_FOLDER\" has been created. Please zip this folder and send it to Redactics support for assistance with troubleshooting agent issues\n"
  ;;

version)
  printf "$VERSION (visit https://app.redactics.com/developers to check on version updates)\n"
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
