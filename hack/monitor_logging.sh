#!/bin/bash

set -euo pipefail

function get_es_pod() {
    # $1 - cluster name postfix
    if [ -z $(oc get -n $LOGPROJ dc -l cluster-name=logging-${1},es-node-role=clientdata --no-headers | awk '{print $1}') ] ; then
      oc get -n $LOGPROJ pods -l component=${1} --no-headers | awk '$3 == "Running" {print $1}'
    else
      oc get -n $LOGPROJ pods -l cluster-name=logging-${1},es-node-role=clientdata --no-headers | awk '$3 == "Running" {print $1}'
    fi
}

get_fluentd_monitor_stats() {
    # $1 is name of pod
    oc exec -n $LOGPROJ $1 -- curl -s http://localhost:24220/api/plugins.json | \
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
        date +%s
        oc exec -n $LOGPROJ $espod -- curl -s -k --cert /etc/elasticsearch/secret/admin-cert \
           --key /etc/elasticsearch/secret/admin-key \
           https://localhost:9200/_cat/thread_pool?v\&h=host,bc,ba,bq,bs,br
        sleep 1
    done > $logdir/$espod.bulk 2>&1 & killpids="$killpids $!"
    stdbuf -o 0 oc exec -n $LOGPROJ $espod -- top -b -d 1 > $logdir/$espod.top.raw & killpids="$killpids $!"
    while true ; do
        oc exec -n $LOGPROJ $espod -- curl -s -k --cert /etc/elasticsearch/secret/admin-cert \
           --key /etc/elasticsearch/secret/admin-key \
           https://localhost:9200/_cat/count?h=epoch,count
        sleep 1
    done > $logdir/$espod.count 2>&1 & killpids="$killpids $!"

    if [ $espod != $esopspod ] ; then
        while true ; do
            date +%s
            oc exec -n $LOGPROJ $esopspod -- curl -s -k --cert /etc/elasticsearch/secret/admin-cert \
               --key /etc/elasticsearch/secret/admin-key \
               https://localhost:9200/_cat/thread_pool?v\&h=host,bc,ba,bq,bs,br
            sleep 1
        done > $logdir/$esopspod.bulk 2>&1 & killpids="$killpids $!"
        stdbuf -o 0 oc exec -n $LOGPROJ $esopspod -- top -b -d 1 > $logdir/$esopspod.top.raw & killpids="$killpids $!"
        while true ; do
            oc exec -n $LOGPROJ $esopspod -- curl -s -k --cert /etc/elasticsearch/secret/admin-cert \
               --key /etc/elasticsearch/secret/admin-key \
               https://localhost:9200/_cat/count?h=epoch,count
            sleep 1
        done > $logdir/$esopspod.count 2>&1 & killpids="$killpids $!"

    fi
}

check_current_ovirt_hosts() {
    local starttime=${1:-"3h"}
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
    if oc exec -n $LOGPROJ -i $espod -- curl -s -k --cert $secret/admin-cert --key $secret/admin-key \
          https://localhost:9200/_cat/indices | grep -q project.ovirt-metrics ; then
        : # has indices
    else
        echo Date: "$( date )" Info: no ovirt-metrics indices yet
        return
    fi
    hostqueryres=$logdir/hostqueryres
    cat $hostquery | \
        oc exec -n $LOGPROJ -i $espod -- curl -s -k --cert $secret/admin-cert --key $secret/admin-key \
           https://localhost:9200/project.ovirt-metrics-*/_search -X POST --data-binary @- > $hostqueryres
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
' 10 20
}

cleanup() {
    local result_code=$?
    set +e
    kill $killpids
    for pod in $pods $espod $esopspod ; do
        oc logs -n $LOGPROJ $pod > $logdir/$pod.pod.log
    done
    free -h > $logdir/free.out
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

pods=
if [ $USE_MUX = 1 ] ; then
    muxpods=$( oc get -n $LOGPROJ pods -l component=mux -o jsonpath='{.items[*].metadata.name}' )
    pods="$pods $muxpods"
fi
if [ $USE_FLUENTD = 1 ] ; then
    fpods=$( oc get -n $LOGPROJ pods -l component=fluentd -o jsonpath='{.items[*].metadata.name}' )
    pods="$pods $fpods"
fi

killpids=""
for pod in $pods ; do
    while true ; do
        get_fluentd_monitor_stats $pod
        sleep 1
    done > $logdir/$pod.stats 2>&1 & killpids="$killpids $!"
    stdbuf -o 0 oc exec -n $LOGPROJ $pod -- top -b -d 1 > $logdir/$pod.top.raw & killpids="$killpids $!"
done

get_all_es_monitor_stats

if [ "${GET_OVIRT_STATS:-false}" = true ] ; then
    while true; do
        check_current_ovirt_hosts
        sleep 10 # expensive - not every second
    done > $logdir/ovirt-hosts.out 2>&1 & killpids="$killpids $!"
fi

while true; do
    df -h | head
    sleep 1
done > $logdir/df.out 2>&1 & killpids="$killpids $!"

echo logdir is $logdir - waiting for $killpids
wait
