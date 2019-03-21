#!/bin/bash

if ! type -t os::log::info > /dev/null ; then
    source "${OS_O_A_L_DIR:-..}/hack/lib/init.sh"
fi

LOGGING_NS=${LOGGING_NS:-openshift-logging}

function get_es_dcs() {
    oc get dc --selector logging-infra=elasticsearch ${1:+-l component=$1} -o name
}

function get_curator_dcs() {
    oc get dc --selector logging-infra=curator -o name
}

function get_es_pod() {
    local clustertype="$1"
    # $1 - cluster name postfix
    # for allinone there is just "elasticsearch"
    # for split apps/infra there will be separate elasticsearch-app and elasticsearch-infra
    if [ -n "$( oc -n $LOGGING_NS get deployment -l cluster-name=elasticsearch,es-node-master=true -o name 2> /dev/null )" ] ; then
        oc -n $LOGGING_NS get pod -l cluster-name=elasticsearch,es-node-master=true --no-headers 2> /dev/null | awk '$3 == "Running" {print $1}'
    elif [ $clustertype = es-ops ] && \
         [ -n "$( oc -n $LOGGING_NS get deployment -l cluster-name=elasticsearch-infra,es-node-master=true -o name 2> /dev/null )" ] ; then
        oc -n $LOGGING_NS get pod -l cluster-name=elasticsearch-infra,es-node-master=true --no-headers 2> /dev/null | awk '$3 == "Running" {print $1}'
    elif [ $clustertype = es ] && \
         [ -n "$( oc -n $LOGGING_NS get deployment -l cluster-name=elasticsearch-app,es-node-master=true -o name 2> /dev/null )" ] ; then
        oc -n $LOGGING_NS get pod -l cluster-name=elasticsearch-app,es-node-master=true --no-headers 2> /dev/null | awk '$3 == "Running" {print $1}'
    elif [ -z "$(oc -n $LOGGING_NS get dc -l cluster-name=logging-${clustertype},es-node-role=clientdata --no-headers 2> /dev/null | awk '{print $1}')" ] ; then
      oc -n $LOGGING_NS get pods -l component=${clustertype} --no-headers 2> /dev/null | awk '$3 == "Running" {print $1}'
    else
      oc -n $LOGGING_NS get pods -l cluster-name=logging-${clustertype},es-node-role=clientdata --no-headers 2> /dev/null | awk '$3 == "Running" {print $1}'
    fi
}

function get_es_svc() {
    local clustertype="$1"
    # $1 - cluster name postfix
    if oc -n $LOGGING_NS get svc elasticsearch -o jsonpath='{.metadata.name}' 2> /dev/null ; then
        return 0
    elif [ $clustertype = es-ops ] && oc -n $LOGGING_NS get svc elasticsearch-infra -o jsonpath='{.metadata.name}' 2> /dev/null ; then
        return 0
    elif [ $clustertype = es ] && oc -n $LOGGING_NS get svc elasticsearch-app -o jsonpath='{.metadata.name}' 2> /dev/null ; then
        return 0
    else
        oc -n $LOGGING_NS get svc logging-$clustertype -o jsonpath='{.metadata.name}' 2> /dev/null || {
            if [ "$clustertype" != "es-ops" ] ; then
                # ignore missing es-ops - probably not deployed with ops cluster - otherwise, report it
                oc -n $LOGGING_NS get svc logging-$clustertype -o jsonpath='{.metadata.name}' 2>&1 | artifact_out || :
            fi
        }
    fi
}

function get_running_pod() {
    # $1 is component for selector
    oc get pods -l component=$1 --no-headers 2> /dev/null | awk '$3 == "Running" {print $1}'
}


function get_completed_pod() {
    # $1 is component for selector
    oc get pods -l component=$1 --no-headers 2> /dev/null | awk '$3 == "Completed" {print $1}'
}

function get_error_pod() {
    # $1 is component for selector
    oc get pods -l component=$1 --no-headers 2> /dev/null | awk '$3 == "Error" {print $1}'
}

function get_es_cert_path() {

  if [ ! -d "${OS_O_A_L_DIR}/temp/es_certs" ]; then
    mkdir -p ${OS_O_A_L_DIR}/temp/es_certs
    if oc get secret/elasticsearch > /dev/null 2>&1 ; then
        oc extract -n $LOGGING_NS secret/elasticsearch --to=${OS_O_A_L_DIR}/temp/es_certs
    else
        oc extract -n $LOGGING_NS secret/logging-elasticsearch --to=${OS_O_A_L_DIR}/temp/es_certs
    fi
  fi

  echo ${OS_O_A_L_DIR}/temp/es_certs
}

# set the test_token, test_name, and test_ip for token auth
function get_test_user_token() {
    local current_project; current_project="$( oc project -q )"
    oc login --username=${1:-${LOG_ADMIN_USER:-admin}} --password=${2:-${LOG_ADMIN_PW:-admin}} > /dev/null
    test_token="$(oc whoami -t)"
    test_name="$(oc whoami)"
    test_ip="127.0.0.1"
    oc login --username=system:admin > /dev/null
    oc project "${current_project}" > /dev/null
}

# $1 - kibana pod name
# $2 - es hostname (e.g. logging-es or logging-es-ops) - should be output of get_es_svc es or es-ops
# $3 - endpoint (e.g. /projects.*/_search)
# $4 - token
# stdout is the JSON output from Elasticsearch
# stderr is curl errors
curl_es_from_kibana() {
    local pod="$1"
    local eshost="$2"
    local endpoint="$3"
    local test_token="$4"
    shift; shift; shift; shift
    local args=( "${@:-}" )

    local secret_dir="/etc/kibana/keys/"
    oc -n $LOGGING_NS exec "${pod}" -c kibana -- curl --connect-timeout 1 --silent --insecure "${args[@]}" \
       --cert "${secret_dir}cert" \
       --key "${secret_dir}key" \
       -H "Authorization: Bearer $test_token" \
       -H "X-Forwarded-For: 127.0.0.1" \
       "https://${eshost}:9200${endpoint}"
}

# $1 - es pod name
# $2 - es endpoint
# rest - any args to pass to curl
function curl_es_pod() {
    local pod="$1"
    local endpoint="$2"
    shift; shift
    local args=( "${@:-}" )

    local secret_dir="/etc/elasticsearch/secret/"
    oc -n $LOGGING_NS exec -c elasticsearch "${pod}" -- curl --silent --insecure "${args[@]}" \
                             --key "${secret_dir}admin-key"   \
                             --cert "${secret_dir}admin-cert" \
                             "https://localhost:9200${endpoint}"
}

# $1 - es svc name
# $2 - es endpoint
# rest - any args to pass to curl
function curl_es() {
    local svc_name="$1"
    local endpoint="$2"
    shift; shift
    local args=( "${@:-}" )
    local secret_dir="$(get_es_cert_path)/"
    local cert=${CURL_ES_CERT:-${secret_dir}/admin-cert}
    local key=${CURL_ES_KEY:-${secret_dir}/admin-key}

    curl --silent --insecure "${args[@]}" \
      --key "${key}" \
      --cert "${cert}" \
      "https://${svc_name}.${LOGGING_NS}.svc:9200${endpoint}"
}

# $1 - es svc name
# $2 - es endpoint
# rest - any args to pass to curl
function curl_es_input() {
    local svc_name="$1"
    local endpoint="$2"
    shift; shift
    local args=( "${@:-}" )
    local secret_dir="$(get_es_cert_path)/"
    local cert=${CURL_ES_CERT:-${secret_dir}/admin-cert}
    local key=${CURL_ES_KEY:-${secret_dir}/admin-key}

    curl --silent --insecure "${args[@]}" \
      --key "${key}"   \
      --cert "${cert}" \
      "https://${svc_name}.${LOGGING_NS}.svc:9200${endpoint}"
}

function curl_es_pod_with_token() {
    local pod="$1"
    local endpoint="$2"
    local test_token="$3"
    shift; shift; shift;
    local args=( "${@:-}" )
    oc -n $LOGGING_NS exec -c elasticsearch "${pod}" -- curl --silent --insecure "${args[@]}" \
                             -H "Authorization: Bearer $test_token" \
                             -H "X-Forwarded-For: 127.0.0.1" \
                             "https://localhost:9200${endpoint}"
}

function curl_es_pod_with_username_password() {
    local pod="$1"
    local endpoint="$2"
    local test_name="$3"
    local test_password="$4"
    shift; shift; shift; shift
    local args=( "${@:-}" )

    oc -n $LOGGING_NS exec -c elasticsearch "${pod}" -- curl --silent --insecure "${args[@]}" \
                             -H "Authorization: Basic $( echo -n ${test_name}:${test_password} | base64 -w 0 )" \
                             "https://localhost:9200${endpoint}"
}

function curl_es_pod_with_username_password_not_silent() {
    local pod="$1"
    local endpoint="$2"
    local test_name="$3"
    local test_password="$4"
    shift; shift; shift; shift
    local args=( "${@:-}" )

    oc -n $LOGGING_NS exec -c elasticsearch "${pod}" -- curl --insecure "${args[@]}" \
                             -H "Authorization: Basic $( echo -n ${test_name}:${test_password} | base64 -w 0 )" \
                             "https://localhost:9200${endpoint}"
}

function curl_es_with_token() {
    local svc_name="$1"
    local endpoint="$2"
    local test_token="$3"
    shift; shift; shift
    local args=( "${@:-}" )

    curl --silent --insecure "${args[@]}" \
      -H "Authorization: Bearer $test_token" \
      "https://${svc_name}:9200${endpoint}"
}

function curl_es_pod_with_token_and_input() {
    local pod="$1"
    local endpoint="$2"
    local test_token="$3"
    shift; shift; shift
    local args=( "${@:-}" )

    oc -n $LOGGING_NS exec -c elasticsearch -i "${pod}" -- curl --silent --insecure "${args[@]}" \
                             -H "Authorization: Bearer $test_token" \
                             -H "Content-type: application/json" \
                             "https://localhost:9200${endpoint}"
}

function curl_es_with_token_and_input() {
    local svc_name="$1"
    local endpoint="$2"
    local test_token="$3"
    shift; shift; shift
    local args=( "${@:-}" )

    curl --silent --insecure "${args[@]}" \
      -H "Authorization: Bearer $test_token" \
      -H "Content-type: application/json" \
      "https://${svc_name}.${LOGGING_NS}:9200${endpoint}"
}

# $1 - es pod name
# $2 - index name (e.g. project.logging, project.test, .operations, etc.)
# $3 - _count or _search
# $4 - field to search
# $5 - search string
# stdout is the JSON output from Elasticsearch
# stderr is curl errors
function query_es_from_es() {
    curl_es_pod "$1" "/${2}*/${3}?q=${4}:${5}" --connect-timeout 1
}

function get_count_from_json() {
    python -c 'import json, sys; print json.loads(sys.stdin.read()).get("count", 0)'
}

# https://github.com/ViaQ/integration-tests/issues/8
function get_count_from_json_from_search() {
    python -c 'import json, sys; print json.loads(sys.stdin.read()).get("responses", [{}])[0].get("hits", {}).get("total", 0)'
}

# $1 - unique value to search for in es
function add_test_message() {
    local kib_pod=`get_running_pod kibana`
    oc -n $LOGGING_NS exec $kib_pod -c kibana -- curl --connect-timeout 1 -s \
       http://localhost:5601/$1 > /dev/null 2>&1
}

function flush_fluentd_pos_files() {
    os::cmd::expect_success "sudo rm -f /var/log/journal.pos /var/log/journal_pos.json"
}

function get_journal_pos_cursor() {
    if sudo test -s /var/log/journal.pos ; then
        sudo cat /var/log/journal.pos
    elif sudo test -s /var/log/journal_pos.json ; then
        sudo python -c 'import sys,json; print json.load(file(sys.argv[1]))["journal"]' /var/log/journal_pos.json
    else
        echo ""
    fi
}

# $1 - command to call to pass the uuid_es
# $2 - command to call to pass the uuid_es_ops
# $3 - expected number of matches
function wait_for_fluentd_to_catch_up() {
    local starttime=$( date +%s.%9N )
    local startsecs=$( date --date=@${starttime} +%s )
    local startjournal="$( date +'%Y-%m-%d %H:%M:%S' --date=@$starttime )"
    os::log::debug START wait_for_fluentd_to_catch_up at $( date --date=@${starttime} -u --rfc-3339=ns )
    local es_svc=$( get_es_svc es )
    local es_ops_svc=$( get_es_svc es-ops )
    es_ops_svc=${es_ops_svc:-$es_svc}
    local uuid_es=${APPS_MESSAGE:-$( uuidgen | sed 's/[-]//g' )}
    local uuid_es_ops=${OPS_MESSAGE:-$( uuidgen | sed 's/[-]//g' )}
    local expected=${3:-1}
    local timeout=${TIMEOUT:-600}
    local appsproject=${4:-$LOGGING_NS}
    local priority=${TEST_REC_PRIORITY:-info}

    wait_for_fluentd_ready

    # look for the messages in the source
    local fullmsg="GET /${uuid_es} 404 "
    local checkpids
    if docker_uses_journal ; then
        sudo journalctl -m -f -o export | \
            awk -v "es=MESSAGE=.*$fullmsg" -v "es_ops=SYSLOG_IDENTIFIER=$uuid_es_ops" \
            -v es_out=$ARTIFACT_DIR/es_out.txt -v es_ops_out=$ARTIFACT_DIR/es_ops_out.txt '
                BEGIN{RS="";FS="\n"};
                $0 ~ es {print > es_out; app += 1; if (app && op) {exit 0}};
                $0 ~ es_ops {print > es_ops_out; op += 1; if (app && op) {exit 0}};
                ' 2>&1 | artifact_out & checkpids=$!
    else
        sudo journalctl -m -f -o export | \
            awk -v "es_ops=SYSLOG_IDENTIFIER=$uuid_es_ops" -v es_ops_out=$ARTIFACT_DIR/es_ops_out.txt '
                BEGIN{RS="";FS="\n"};
                $0 ~ es_ops {print > es_ops_out; exit 0}' 2>&1 | artifact_out & checkpids=$!
        while ! sudo find /var/log/containers -name \*.log -exec grep -b -n "$fullmsg" {} + > $ARTIFACT_DIR/es_out.txt 2> $ARTIFACT_DIR/es_errs.txt ; do
            sleep 1
        done & checkpids="$checkpids $!"
    fi

    add_test_message $uuid_es
    artifact_log added es message $uuid_es
    logger -i -p local6.${priority} -t $uuid_es_ops $uuid_es_ops
    artifact_log added es-ops message $uuid_es_ops

    local errqs
    local rc=0
    local qs='{"query":{"bool":{"filter":{"match_phrase":{"message":"'"${fullmsg}"'"}},"must":{"term":{"kubernetes.container_name":"kibana"}}}}}'
    case "${appsproject}" in
    default|openshift|openshift-*) logging_index=".operations.*" ; es_svc=$es_ops_svc ;;
    *) logging_index="project.${appsproject}.*" ;;
    esac

    # poll for logs to show up
    if os::cmd::try_until_text "curl_es ${es_svc} /${logging_index}/_count -X POST -d '$qs' | get_count_from_json" $expected $(( timeout * second )); then
        artifact_log good - $FUNCNAME: found $expected record $logging_index for \'$fullmsg\'
        if [ -n "${1:-}" ] ; then
            curl_es ${es_svc} /${logging_index}/_count -X POST -d "$qs" 2>&1 | artifact_out
            curl_es ${es_svc} /${logging_index}/_count -X POST -d "$qs" 2>&1 | get_count_from_json | artifact_out
            curl_es ${es_svc} "/${logging_index}/_search" -X POST -d "$qs" | jq . > $ARTIFACT_DIR/apps.json
            $1 $uuid_es $ARTIFACT_DIR/apps.json
        fi
    else
        os::log::error $FUNCNAME: not found $expected record $logging_index for \'$fullmsg\' after $timeout seconds
        curl_es ${es_svc} /${logging_index}/_search -X POST -d "$qs" > $ARTIFACT_DIR/apps_search_output.raw 2>&1 || :
        if [ -s $ARTIFACT_DIR/es_out.txt ] ; then
            os::log::error "$( cat $ARTIFACT_DIR/es_out.txt )"
        else
            os::log::error apps record for "$fullmsg" not found in source
        fi
        if docker_uses_journal ; then
            os::log::error here is the current fluentd journal cursor
            sudo cat /var/log/journal.pos || :
            sudo cat /var/log/journal_pos.json || :
            echo ""
            os::log::error starttime in journald format is $( date --date=@$starttime +%s%6N )
            # first and last couple of records in the journal
            sudo journalctl -m -S "$startjournal" -n 20 -o export > $ARTIFACT_DIR/apps_err_journal_first.txt
            sudo journalctl -m -S "$startjournal" -r -n 20 -o export > $ARTIFACT_DIR/apps_err_journal_last.txt
        elif sudo test -f /var/log/es-containers.log.pos ; then
            sudo cat /var/log/es-containers.log.pos > $ARTIFACT_DIR/es-containers.log.pos
        fi
        # records since start of function in ascending @timestamp order - see what records were added around
        # the time our record should have been added
        errqs='{"query":{"range":{"@timestamp":{"gte":"'"$( date --date=@${starttime} -u -Ins )"'"}}},"sort":[{"@timestamp":{"order":"asc"}}],"size":20}'
        curl_es ${es_svc} /${logging_index}/_search -X POST -d "$errqs" | jq . > $ARTIFACT_DIR/apps_err_recs_asc.json 2>&1 || :
        # last records in descending @timestamp order - see what records have been added recently
        errqs='{"query":{"range":{"@timestamp":{"gte":"'"$( date --date=@${starttime} -u -Ins )"'"}}},"sort":[{"@timestamp":{"order":"desc"}}],"size":20}'
        curl_es ${es_svc} /${logging_index}/_search -X POST -d "$errqs" | jq . > $ARTIFACT_DIR/apps_err_recs_desc.json 2>&1 || :
        rc=1
    fi

    qs='{"query":{"term":{"systemd.u.SYSLOG_IDENTIFIER":"'"${uuid_es_ops}"'"}}}'
    if os::cmd::try_until_text "curl_es ${es_ops_svc} /.operations.*/_count -X POST -d '$qs' | get_count_from_json" $expected $(( timeout * second )); then
        os::log::debug good - $FUNCNAME: found $expected record .operations for $uuid_es_ops
        if [ -n "${2:-}" ] ; then
            curl_es ${es_ops_svc} "/.operations.*/_search" -X POST -d "$qs" | jq . > $ARTIFACT_DIR/ops.json
            $2 $uuid_es_ops $ARTIFACT_DIR/ops.json
        fi
    else
        os::log::error $FUNCNAME: not found $expected record .operations for $uuid_es_ops after $timeout seconds
        curl_es ${es_ops_svc} /.operations.*/_search -X POST -d "$qs" > $ARTIFACT_DIR/ops_search_output.raw 2>&1 || :
        os::log::error "Checking journal for $uuid_es_ops..."
        if [ -s $ARTIFACT_DIR/es_ops_out.txt ] ; then
            os::log::error "$( cat $ARTIFACT_DIR/es_ops_out.txt )"
        else
            os::log::error ops record for "$uuid_es_ops" not found in journal
        fi
        os::log::error here is the current fluentd journal cursor
        sudo cat /var/log/journal.pos || :
        sudo cat /var/log/journal_pos.json || :
        echo ""
        os::log::error starttime in journald format is $( date --date=@$starttime +%s%6N )
        # first and last couple of records in the journal
        sudo journalctl -m -S "$startjournal" -n 20 -o export > $ARTIFACT_DIR/ops_err_journal_first.txt
        sudo journalctl -m -S "$startjournal" -r -n 20 -o export > $ARTIFACT_DIR/ops_err_journal_last.txt
        # records since start of function in ascending @timestamp order - see what records were added around
        # the time our record should have been added
        errqs='{"query":{"range":{"@timestamp":{"gte":"'"$( date --date=@${starttime} -u -Ins )"'"}}},"sort":[{"@timestamp":{"order":"asc"}}],"size":20}'
        curl_es ${es_ops_svc} /.operations.*/_search -X POST -d "$errqs" | jq . > $ARTIFACT_DIR/ops_err_recs_asc.json 2>&1 || :
        # last records in descending @timestamp order - see what records have been added recently
        errqs='{"query":{"range":{"@timestamp":{"gte":"'"$( date --date=@${starttime} -u -Ins )"'"}}},"sort":[{"@timestamp":{"order":"desc"}}],"size":20}'
        curl_es ${es_ops_svc} /.operations.*/_search -X POST -d "$errqs" | jq . > $ARTIFACT_DIR/ops_err_recs_desc.json 2>&1 || :
        rc=1
    fi

    kill $checkpids > /dev/null 2>&1 || :
    kill -9 $checkpids > /dev/null 2>&1 || :

    local endtime=$( date +%s.%9N )
    local endsecs=$( date --date=@${endtime} +%s )
    os::log::debug END wait_for_fluentd_to_catch_up took $( expr $endsecs - $startsecs ) seconds at $( date --date=@${endtime} -u --rfc-3339=ns )
    return $rc
}

docker_uses_journal() {
    # note the unintuitive logic - in this case, a 0 return means true, and a 1
    # return means false
    # need to be able to handle cases like
    # OPTIONS='--log-driver=json-file ....' # or use --log-driver=journald
    # if "log-driver" is set in /etc/docker/daemon.json, assume that it is
    # authoritative
    # otherwise, look for /etc/sysconfig/docker
    if type -p docker > /dev/null && sudo docker info 2>&1 | grep -q 'Logging Driver: journald' ; then
        return 0
    elif sudo grep -q '^[^#].*"log-driver":' /etc/docker/daemon.json 2> /dev/null ; then
        if sudo grep -q '^[^#].*"log-driver":.*journald' /etc/docker/daemon.json 2> /dev/null ; then
            return 0
        fi
    elif sudo grep -q "^OPTIONS='[^']*--log-driver=journald" /etc/sysconfig/docker 2> /dev/null ; then
        return 0
    fi
    return 1
}

wait_for_fluentd_ready() {
    local timeout=${1:-60}
    # wait until fluentd is actively reading from the source (journal or files)
    os::cmd::try_until_success "sudo test -s /var/log/journal.pos -o -s /var/log/journal_pos.json" $(( timeout * second ))
    if docker_uses_journal ; then
        : # done
    else
        os::cmd::try_until_success "sudo test -f /var/log/es-containers.log.pos" $(( timeout * second ))
    fi
}

extra_artifacts_testname=$( basename $0 )
extra_artifacts=$ARTIFACT_DIR/${extra_artifacts_testname}-artifacts.txt
internal_artifact_log() {
    local ts=$1 ; shift
    echo \[${ts}\] "$@" >> $extra_artifacts
}
artifact_log() {
    internal_artifact_log "$( date +%Y-%m-%dT%H:%M:%S.%3N%z )" "$@"
}
artifact_out() {
    local ts="$( date +%Y-%m-%dT%H:%M:%S.%3N%z )"
    local line
    while IFS= read -r line ; do
        internal_artifact_log "${ts}" "$line"
    done
}

# e.g. 2 or 5 or 6
get_es_major_ver() {
    local es_svc=$( get_es_svc es )
    curl_es $es_svc "/" | jq -r '.version.number | split(".")[0]'
}

# fields are given like this: c a r s q
get_bulk_thread_pool_url() {
    local es_ver=$1
    local headers=$2
    shift; shift
    # remaining args are fields
    local url="/_cat/thread_pool"
    local comma=""
    local pref=""

    if [ "${es_ver}" -gt 2 ] ; then
        url="${url}/bulk"
    else
        pref="b"
    fi
    url="${url}?"
    if [ -n "${headers}" ] ; then
        url="${url}v&h="
    else
        url="${url}h="
    fi
    while [ -n "${1:-}" ] ; do
        url="${url}${comma}${pref}$1"
        comma=,
        shift
    done
    echo $url
}

# fluentd may have pod logs and logs in the file
get_fluentd_pod_log() {
    local pod=${1:-$( get_running_pod fluentd )}
    local logfile=${2:-/var/log/fluentd/fluentd.log}
    oc logs $pod 2>&1
    if oc exec $pod -- logs 2>&1 ; then
        : # done
    elif sudo test -f $logfile ; then
        # can't read from the pod directly - see if we can get the log file
        sudo cat $logfile
    fi
}

get_mux_pod_log() {
    local pod=${1:-$( get_running_pod mux )}
    local logfile=${2:-/var/log/fluentd/fluentd.log}
    oc logs $pod 2>&1
    oc exec $pod -- cat $logfile 2> /dev/null || :
}

# writes all pod logs to the given outdir or $ARTIFACT_DIR in the form
# pod_name.container_name.log
# it will get both the oc logs output and any log files produced by
# the pod
get_all_logging_pod_logs() {
  local outdir=${1:-$ARTIFACT_DIR}
  local p
  local container
  for p in $(oc get pods -n ${LOGGING_NS} -o jsonpath='{.items[*].metadata.name}') ; do
    for container in $(oc get po $p -o jsonpath='{.spec.containers[*].name}') ; do
      case "$p" in
        logging-fluentd-*|fluentd-*) get_fluentd_pod_log $p > $ARTIFACT_DIR/$p.$container.log 2>&1 ;;
        logging-mux-*) get_mux_pod_log $p > $ARTIFACT_DIR/$p.$container.log 2>&1 ;;
        logging-es-*|elasticsearch-*) oc logs -n ${LOGGING_NS} -c $container $p > $ARTIFACT_DIR/$p.$container.log 2>&1
                      oc exec -c elasticsearch -n ${LOGGING_NS} $p -- logs >> $ARTIFACT_DIR/$p.$container.log 2>&1
                      ;;
	    *) oc logs -n ${LOGGING_NS} -c $container $p > $ARTIFACT_DIR/$p.$container.log 2>&1 ;;
      esac
	done
  done
}

stop_fluentd() {
    local fpod=${1:-$( get_running_pod fluentd )}
    local wait_time=${2:-$(( 2 * minute ))}

    oc label node -l logging-infra-fluentd=true --overwrite logging-infra-fluentd=false
    os::cmd::try_until_text "oc get $fluentd_ds -o jsonpath='{ .status.numberReady }'" "0" $wait_time
    # not sure if it is a bug or a flake, but sometimes .status.numberReady is 0, the fluentd pod hangs around
    # in the Terminating state for many seconds, which seems to cause problems with subsequent tests
    # so, we have to wait for the pod to completely disappear - we cannot rely on .status.numberReady == 0
    if [ -n "${fpod:-}" ] ; then
        os::cmd::try_until_failure "oc get pod $fpod > /dev/null 2>&1" $wait_time
    fi
}

start_fluentd() {
    local cleanfirst=${1:-false}
    local wait_time=${2:-$(( 2 * minute ))}

    if [ "$cleanfirst" != false ] ; then
        flush_fluentd_pos_files
        sudo rm -rf /var/log/fluentd/fluentd.log
        if [ "${CLEANBUFFERS:-true}" = true ] ; then
            sudo rm -rf /var/lib/fluentd/*
        fi
    fi
    oc label node -l logging-infra-fluentd=false --overwrite logging-infra-fluentd=true
    os::cmd::try_until_text "oc get pods -l component=fluentd" "^(logging-)*fluentd-.* Running " $wait_time
}

get_fluentd_ds_name() {
    if oc -n ${LOGGING_NS} get daemonset fluentd -o name > /dev/null 2>&1 ; then
        echo daemonset/fluentd
    else
        echo daemonset/logging-fluentd
    fi
}

fluentd_ds=${fluentd_ds:-$(get_fluentd_ds_name)}

get_fluentd_cm_name() {
    if oc -n ${LOGGING_NS} get configmap fluentd -o name > /dev/null 2>&1 ; then
        echo configmap/fluentd
    else
        echo configmap/logging-fluentd
    fi
}

fluentd_cm=${fluentd_cm:-$(get_fluentd_cm_name)}
