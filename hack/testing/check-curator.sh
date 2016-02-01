#!/bin/bash

if [[ $VERBOSE ]]; then
  set -ex
else
  set -e
fi

if [[ $# -ne 1 ]]; then
  # assuming not using OPS cluster
  CLUSTER="false"
else
  CLUSTER="$1"
fi

TEST_DIVIDER="------------------------------------------"

# projects:
# project-dev-YYYY.mm.dd delete 24 hours
# project-qe-YYYY.mm.dd delete 7 days
# project-prod-YYYY.mm.dd delete 4 weeks
# .operations-YYYY.mm.dd delete 2 months

# use the fluentd credentials to add records and indices for these projects
# oc get secret logging-fluentd --template='{{.data.ca}}' | base64 -d > ca-fluentd
# ca=./ca-fluentd
# oc get secret logging-fluentd --template='{{.data.key}}' | base64 -d > key-fluentd
# key=./key-fluentd
# oc get secret logging-fluentd --template='{{.data.cert}}' | base64 -d > cert-fluentd
# cert=./cert-fluentd
fpod=`oc get pods | awk '/-deploy/ {next}; /-build/ {next}; /^logging-fluentd-.* Running / {print $1}'`

# where "yesterday", "today", etc. are the dates in UTC in YYYY.mm.dd format
tf='%Y.%m.%d'
today=`date -u +"$tf"`
yesterday=`date -u +"$tf" --date=yesterday`
lastweek=`date -u +"$tf" --date="last week"`
fourweeksago=`date -u +"$tf" --date="4 weeks ago"`
twomonthsago=`date -u +"$tf" --date="2 months ago"`
# project-dev-yesterday project-dev-today
# project-qe-lastweek project-qe-today
# project-prod-4weeksago project-today
# .operations-2monthsago .operations-today

add_message_to_index() {
    # index is $1
    # message is $2
    message=${2:-"curatortest message"}
    ca=/etc/fluent/keys/ca
    cert=/etc/fluent/keys/cert
    key=/etc/fluent/keys/key
    url="https://logging-es:9200/$1/curatortest/"
    oc exec $fpod -- curl -s --cacert $ca --cert $cert --key $key -XPOST "$url" -d '{
    "message" : "'"$message"'"
}'
}

set -- project-dev "$today" project-dev "$yesterday" project-qe "$today" project-qe "$lastweek" project-prod "$today" project-prod "$fourweeksago" .operations "$today" .operations "$twomonthsago"
while [ -n "$1" ] ; do
    proj="$1" ; shift
    add_message_to_index "${proj}.$1" "$proj $1 message"
    shift
done

# get current curator pod
curpod=`oc get pods | awk '/-deploy/ {next}; /-build/ {next}; /^logging-curator-.* Running / {print $1}'`
# change dc to use env
INDEX_MGMT='{"project-dev":{"delete":{"hours":"24"}},"project-qe":{"delete":{"days":"7"}},"project-prod":{"delete":{"weeks":"4"}},".operations":{"delete":{"months":"2"}}}'
oc get dc/logging-curator -o yaml | awk -v sq="'" -v index_mgmt="$INDEX_MGMT" '
BEGIN {changenext = 0}
{if (changenext == 1) {
   $0 = gensub(/value: .*$/, "value: " sq index_mgmt sq, 1)
   changenext = 0
 }
 print
}
/name: .*INDEX_MGMT/ {changenext = 1}
' | oc replace -f -
# scale down dc
oc scale --replicas=0 dc logging-curator
# wait for pod to go away
ii=120
incr=10
while [ $ii -gt 0 ] ; do
    if oc describe pod/$curpod > /dev/null ; then
        echo $curpod still running
    else
        break
    fi
    sleep $incr
    ii=`expr $ii - $incr`
done
# scale up dc
oc scale --replicas=1 dc logging-curator
# wait for pod to start
ii=120
incr=10
while [ $ii -gt 0 ] ; do
    curpod=`oc get pods | awk '/-deploy/ {next}; /-build/ {next}; /^logging-curator-.* Running / {print $1}'`
    if [ -n "$curpod" ] ; then
        break
    fi
    sleep $incr
    ii=`expr $ii - $incr`
done
# query ES
curout=`mktemp`
oc exec $curpod -- curator --host logging-es --use_ssl --certificate /etc/curator/keys/ca \
   --client-cert /etc/curator/keys/cert --client-key /etc/curator/keys/key --loglevel ERROR \
   show indices --all-indices > $curout 2>&1
# verify that project-dev-yesterday project-qe-lastweek project-prod-fourweeksago .operations-twomonthsago are deleted
set -- project-dev "$today" project-dev "$yesterday" project-qe "$today" project-qe "$lastweek" project-prod "$today" project-prod "$fourweeksago" .operations "$today" .operations "$twomonthsago"
while [ -n "$1" ] ; do
    proj="$1" ; shift
    idx="${proj}.$1"
    if [ "$1" = "$today" ] ; then
        # index must be present
        if grep \^"$idx"\$ $curout > /dev/null 2>&1 ; then
            echo good - index "$idx" is present
        else
            echo ERROR: index "$idx" is missing
        fi
    else
        # index must be absent
        if grep \^"$idx"\$ $curout > /dev/null 2>&1 ; then
            echo ERROR: index "$idx" was not deleted
        else
            echo good - index "$idx" is missing
        fi
    fi
    shift
done
#rm -f $curout
echo output is $curout
