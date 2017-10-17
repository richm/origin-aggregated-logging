#!/bin/bash

set -euo pipefail

function get_running_pod() {
    # $1 is component for selector
    oc get -n $LOGPROJ pods -l component=$1 --no-headers | awk '$3 == "Running" {print $1}'
}

function get_es_pod() {
    # $1 - cluster name postfix
    if [ -z $(oc get -n $LOGPROJ dc -l cluster-name=logging-${1},es-node-role=clientdata --no-headers | awk '{print $1}') ] ; then
      oc get -n $LOGPROJ pods -l component=${1} --no-headers | awk '$3 == "Running" {print $1}'
    else
      oc get -n $LOGPROJ pods -l cluster-name=logging-${1},es-node-role=clientdata --no-headers | awk '$3 == "Running" {print $1}'
    fi
}

# $1 - es pod name
# $2 - es endpoint
# rest - any args to pass to curl
function curl_es() {
    local pod="$1"
    local endpoint="$2"
    shift; shift
    local args=( "${@:-}" )

    local secret_dir="/etc/elasticsearch/secret/"
    oc exec -n $LOGPROJ -c elasticsearch "${pod}" -- curl --silent --insecure "${args[@]}" \
                             --key "${secret_dir}admin-key"   \
                             --cert "${secret_dir}admin-cert" \
                             "https://localhost:9200${endpoint}"
}

# $1 - es pod name
# $2 - es endpoint
# rest - any args to pass to curl
function curl_es_input() {
    local pod="$1"
    local endpoint="$2"
    shift; shift
    local args=( "${@:-}" )

    local secret_dir="/etc/elasticsearch/secret/"
    oc exec -n $LOGPROJ -c elasticsearch -i "${pod}" -- curl --silent --insecure "${args[@]}" \
                                --key "${secret_dir}admin-key"   \
                                --cert "${secret_dir}admin-cert" \
                                "https://localhost:9200${endpoint}"
}

function curl_fluentd() {
    local pod="$1"
    oc exec -n $LOGPROJ "${pod}" -- curl -s http://localhost:24220/api/plugins.json
}

# note - this never returns unless the pod dies
function top_pod() {
    local pod="$1"
    local containerarg="${2:-}"
    stdbuf -o 0 oc exec -n $LOGPROJ $containerarg "${pod}" -- top -b -d 1
}

function top_pod_once() {
    local pod="$1"
    local containerarg="${2:-}"
    stdbuf -o 0 oc exec -n $LOGPROJ $containerarg "${pod}" -- top -b -n 1
}

get_fluentd_monitor_stats() {
    # $1 is name of pod
    curl_fluentd $1 | \
        python -c 'import sys,json,time
def get_type(plg):
  return plg["config"].get("@type", None) or plg["config"].get("type", None) or plg.get("type")

def is_es(plg):
  return ("elasticsearch" == get_type(plg) or "elasticsearch_dynamic" == get_type(plg)) and ((-1 < plg["config"].get("buffer_path", "").find("output-es-config")) or (plg.get("host") == "logging-es"))

def is_es_ops(plg):
  return ("elasticsearch" == get_type(plg) or "elasticsearch_dynamic" == get_type(plg)) and ((-1 < plg["config"].get("buffer_path", "").find("output-es-ops-config")) or (plg.get("host") == "logging-es-ops"))

stathash = {"time":int(time.time()), "forward":{"bql": 0, "btqs": 0, "retries": 0}, "es":{"bql": 0, "btqs": 0, "retries": 0}, "es-ops":{"bql": 0, "btqs": 0, "retries": 0}}
for plg in json.load(sys.stdin)["plugins"]:
  if "secure_forward" == get_type(plg) and plg["output_plugin"]:
    stathash["forward"]["bql"] = plg["buffer_queue_length"]
    stathash["forward"]["btqs"] = plg["buffer_total_queued_size"]
    stathash["forward"]["retries"] = plg["retry_count"]
  elif is_es_ops(plg):
    stathash["es-ops"]["bql"] = plg["buffer_queue_length"]
    stathash["es-ops"]["btqs"] = plg["buffer_total_queued_size"]
    stathash["es-ops"]["retries"] = plg["retry_count"]
  elif is_es(plg):
    stathash["es"]["bql"] = plg["buffer_queue_length"]
    stathash["es"]["btqs"] = plg["buffer_total_queued_size"]
    stathash["es"]["retries"] = plg["retry_count"]
print "{time} {es[bql]} {es[btqs]} {es[retries]} {es-ops[bql]} {es-ops[btqs]} {es-ops[retries]} {forward[bql]} {forward[btqs]} {forward[retries]}".format(**stathash)
'
}

get_all_es_monitor_stats() {
    if [ "${GET_ES_STATS:-false}" = false ] ; then
        return
    fi
    while true ; do
        if [ -n "$espod" ] ; then
            date +%s >> $logdir/$espod.bulk 2>&1
            curl_es $espod /_cat/thread_pool?h=host,bc,ba,bq,bs,br >> $logdir/$espod.bulk 2>&1 || :
        else
            espod=$( get_es_pod es )
        fi
        sleep 1
    done & killpids="$killpids $!"
    while true ; do
        if [ -n "$espod" ] ; then
            top_pod $espod "-c elasticsearch" >> $logdir/$espod.top.raw 2>&1 || :
        fi
        sleep 1
        espod=$( get_es_pod es )
    done & killpids="$killpids $!"
    while true ; do
        if [ -n "$espod" ] ; then
            curl_es $espod /_cat/count?h=epoch,count >> $logdir/$espod.count 2>&1 || :
        else
            espod=$( get_es_pod es )
        fi
        sleep 1
    done & killpids="$killpids $!"

    if [ $espod != $esopspod ] ; then
        while true ; do
            if [ -n "$esopspod" ] ; then
                date +%s >> $logdir/$esopspod.bulk 2>&1
                curl_es $esopspod /_cat/thread_pool?h=host,bc,ba,bq,bs,br >> $logdir/$esopspod.bulk 2>&1 || :
            else
                esopspod=$( get_es_pod es-ops )
            fi
            sleep 1
        done & killpids="$killpids $!"
        while true ; do
            if [ -n "$esopspod" ] ; then
                top_pod $esopspod "-c elasticsearch" >> $logdir/$esopspod.top.raw 2>&1 || :
            fi
            sleep 1
            esopspod=$( get_es_pod es-ops )
        done & killpids="$killpids $!"
        while true ; do
            if [ -n "$esopspod" ] ; then
                curl_es $esopspod /_cat/count?h=epoch,count >> $logdir/$esopspod.count 2>&1 || :
            else
                esopspod=$( get_es_pod es-ops )
            fi
            sleep 1
        done & killpids="$killpids $!"
    fi
}

check_current_ovirt_hosts() {
    local espod=$1
    local starttime=${2:-"3h"}
    local hostquery=$logdir/hostquery
    cat > $hostquery <<EOF
{
  "size": 0,
  "query": {
    "bool": {
      "filter": {
          "range": {
            "@timestamp": { "gte": "now-${starttime}" }
         }
      }
    }
  },
  "aggs": {
    "hosts": {
      "terms": {
        "size": 40,
        "field": "hostname",
         "order": [
             { "last_update": "desc" },
             { "_term": "asc" }
          ]
      },
      "aggs": {
        "last_update": {
          "max": { "field": "@timestamp" }
        }
     }
    }
  }
}
EOF
    secret=/etc/elasticsearch/secret
    if curl_es $espod /_cat/indices | grep -q project.ovirt-metrics ; then
        : # has indices
    else
        echo Date: "$( date )" Info: no ovirt-metrics indices yet
        return 0
    fi
    hostqueryres=$logdir/hostqueryres
    cat $hostquery | \
        curl_es_input $espod /project.ovirt-metrics-*/_search \
                      -X POST --data-binary @- > $hostqueryres || return 1
    cat $hostqueryres | python -c 'import sys,json
from datetime import datetime,timedelta
from calendar import timegm
warnthresh = timedelta(minutes=int(sys.argv[1]))
errthresh = timedelta(minutes=int(sys.argv[2]))
now = datetime.utcnow()
hsh = json.load(sys.stdin)
for bucket in hsh["aggregations"]["hosts"]["buckets"]:
  recs = bucket["doc_count"]
  hn = bucket["key"]
  tsflt = bucket["last_update"]["value"]
  ts = datetime.utcfromtimestamp(tsflt/1000.0)
  if now - ts > errthresh:
    status = "Error"
  elif now - ts > warnthresh:
    status = "Warning"
  else:
    status = "Info"
  print "{}: {} diff {} records {}".format(status, hn, now-ts, recs)
print "Date: {} time_t: {} Number of hosts: {}".format(now.isoformat(), timegm(now.timetuple()), len(hsh["aggregations"]["hosts"]["buckets"]))
' 5 10
}

cleanup() {
    local result_code=$?
    set +e
    kill $killpids
    for pod in $( oc get -n $LOGPROJ pods -o jsonpath='{.items[*].metadata.name}' ) ; do
        for container in $( oc get -n $LOGPROJ pod $pod -o jsonpath='{.spec.containers[*].name}' ) ; do
            oc logs -n $LOGPROJ -c $container $pod > $logdir/$pod.$container.log
        done
    done
    exit $result_code
}
trap "cleanup" INT TERM EXIT

logdir=${ARTIFACT_DIR:-$( mktemp -d -p /var/tmp )}

LOGPROJ=${LOGPROJ:-logging}

USE_MUX=${USE_MUX:-1}

USE_FLUENTD=${USE_FLUENTD:-1}

espod=$( get_es_pod es )
esopspod=$( get_es_pod es-ops )
esopspod=${esopspod:-$espod}
GET_ES_STATS=${GET_ES_STATS:-true}
GET_OVIRT_STATS=${GET_OVIRT_STATS:-false}

killpids=""

if [ $USE_MUX = 1 ] ; then
    while true ; do
        for muxpod in $( get_running_pod mux ) ; do
            get_fluentd_monitor_stats $muxpod >> $logdir/$muxpod.stats 2>&1 || :
            top_pod_once $muxpod >> $logdir/$muxpod.top.raw || :
        done
        sleep 1
    done & killpids="$killpids $!"
fi

if [ $USE_FLUENTD = 1 ] ; then
    while true ; do
        for fpod in $( get_running_pod fluentd ) ; do
            get_fluentd_monitor_stats $fpod >> $logdir/$fpod.stats 2>&1 || :
            top_pod_once $fpod >> $logdir/$fpod.top.raw || :
        done
        sleep 1
    done & killpids="$killpids $!"
fi

get_all_es_monitor_stats

if [ "${GET_OVIRT_STATS:-false}" = true ] ; then
    while true; do
        if [ -n "$espod" ] ; then
            check_current_ovirt_hosts $espod ${OLDEST:-3h} >> $logdir/ovirt-hosts.out 2>&1 || :
        else
            espod=$( get_es_pod es )
        fi
        sleep 10 # expensive - not every second
    done & killpids="$killpids $!"
fi

while true; do
    date +%s
    df -h | head || :
    sleep 1
done > $logdir/df.out 2>&1 & killpids="$killpids $!"

while true; do
    date +%s
    free -h || :
    sleep 1
done > $logdir/free.out 2>&1 & killpids="$killpids $!"

stdbuf -o 0 sudo journalctl -f | grep -i oom-kill > $logdir/oom-kills.out 2>&1 & killpids="$killpids $!"

echo logdir is $logdir - waiting for $killpids
wait
