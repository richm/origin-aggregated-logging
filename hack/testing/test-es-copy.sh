#!/bin/bash

if [[ $VERBOSE ]]; then
  set -ex
else
  set -e
  VERBOSE=
fi
set -o nounset
set -o pipefail

if ! type get_running_pod > /dev/null 2>&1 ; then
    . ${OS_O_A_L_DIR:-../..}/deployer/scripts/util.sh
fi

if [ -n "${MUX_CLIENT_MODE:-}" ] ; then
    echo "Skipping -- This test does not work with MUX_CLIENT_MODE."
    exit 0
fi

if [[ $# -ne 1 || "$1" = "false" ]]; then
  # assuming not using OPS cluster
  CLUSTER="false"
  ops=
else
  CLUSTER="$1"
  ops="-ops"
fi

# not used for now, but in case
INDEX_PREFIX=
PROJ_PREFIX=project.

ARTIFACT_DIR=${ARTIFACT_DIR:-${TMPDIR:-/tmp}/origin-aggregated-logging}
if [ ! -d $ARTIFACT_DIR ] ; then
    mkdir -p $ARTIFACT_DIR
fi

get_test_user_token

write_and_verify_logs() {
    rc=0
    if ! wait_for_fluentd_to_catch_up "" "" $1 ; then
        rc=1
    fi

    if [ $rc -ne 0 ]; then
        echo test-es-copy.sh: returning $rc ...
    fi
    return $rc
}

undeploy_fluentd() {
    fpod=`get_running_pod fluentd`

    # undeploy fluentd
    oc label node --all logging-infra-fluentd-

    wait_for_pod_ACTION stop $fpod
}

redeploy_fluentd() {
  # redeploy fluentd
  oc label node --all logging-infra-fluentd=true

  # wait for fluentd to start
  wait_for_pod_ACTION start fluentd
}

check_copy_conf () {
  expect=$1
  copy_conf_file=$2
  fpod=`get_running_pod fluentd`
  lsout=$(oc exec $fpod -- ls -l /etc/fluent/configs.d/dynamic/$copy_conf_file 2>&1) || :
  if [ `expr "$lsout" : ".* No such file"` -gt 0 ]; then
    existcopy="false"
    verb="does not exist"
  else
    fsize=`echo $lsout | awk '{print $5}'`
    if [ $fsize -le 1 ]; then
      existcopy="false"
      verb="does not exist"
    else
      existcopy="true"
      verb="exists"
    fi
  fi
  if [ "$expect" = "$existcopy" ]; then
     result="good"
  else
     result="failed"
  fi
  echo "$result - $copy_conf_file $verb."
}

TEST_DIVIDER="------------------------------------------"

# configure fluentd to just use the same ES instance for the copy
# cause messages to be written to a container - verify that ES contains
# two copies
# cause messages to be written to the system log - verify that OPS contains
# two copies

undeploy_fluentd

cfg=`mktemp`
# first, make sure copy is off
oc get daemonset logging-fluentd -o yaml | \
    sed '/- name: ES_COPY/,/value:/ s/value: .*$/value: "false"/' | \
    oc replace -f -

redeploy_fluentd

# run test to make sure fluentd is working normally - no copy
write_and_verify_logs 1 || {
    oc get events -o yaml > $ARTIFACT_DIR/all-events.yaml 2>&1
    exit 1
}

undeploy_fluentd

# save original daemonset config
origconfig=`mktemp`
oc get daemonset logging-fluentd -o yaml > $origconfig

cmap=`mktemp`
oc get configmap/logging-fluentd -o yaml > $cmap

cleanup() {
    # may have already been cleaned up
    cat $cmap | oc replace --force -f - 
    wait_for_pod_ACTION start fluentd

    if [ ! -f $origconfig ] ; then return 0 ; fi
    undeploy_fluentd
    # put back original configuration
    oc replace --force -f $origconfig
    rm -f $origconfig
    redeploy_fluentd
}
trap "cleanup" INT TERM EXIT

nocopy=`mktemp`
# strip off the copy settings, if any
sed '/_COPY/,/value/d' $origconfig > $nocopy
# for every ES_ or OPS_ setting, create a copy called ES_COPY_ or OPS_COPY_
envpatch=`mktemp`
sed -n '/^ *- env:/,/^ *image:/ {
/^ *image:/d
/^ *- env:/d
/name: K8S_HOST_URL/,/value/d
/name: .*JOURNAL.*/,/value/d
/name: .*BUFFER.*/,/value/d
/name: .*MUX.*/,/value/d
/name: FLUENTD_.*_LIMIT/,/valueFrom:/d
/resourceFieldRef:/,/containerName: fluentd-elasticsearch/d
/divisor:/,/resource: limits./d
s/ES_/ES_COPY_/
s/OPS_/OPS_COPY_/
p
}' $nocopy > $envpatch

# add the scheme, and turn on verbose
cat >> $envpatch <<EOF
        - name: ES_COPY
          value: "true"
        - name: ES_COPY_SCHEME
          value: https
        - name: OPS_COPY_SCHEME
          value: https
        - name: VERBOSE
          value: "true"
EOF

# add this back to the dc config
docopy=`mktemp`
cat $nocopy | sed '/^ *- env:/r '$envpatch > $docopy

cat $docopy | oc replace -f -

redeploy_fluentd
rm -f $docopy

check_copy_conf false "es-copy-config.conf"
check_copy_conf false "es-ops-copy-config.conf"

# Check warnings.
fpod=`get_running_pod fluentd`
logs=$(oc logs $fpod | egrep "Disabling the copy") || :
if [ -z "$logs" ]; then
    echo "failed - No expected warning message."
else
    echo "good - Expected warning message found -- $logs."
fi

# Fluentd does not configure copy outputs unless the output ES has
# the separate hostname and port.
write_and_verify_logs 1 || {
    oc get events -o yaml > $ARTIFACT_DIR/all-events.yaml 2>&1
    exit 1
}

# Let the target es of copy output have their own name
workcopy=`mktemp`
sed '/^ *- name: ES_COPY_HOST/ {
$!{N;s/value: \(.*\)/value: \1-copy/}
}'  $envpatch > $workcopy

sed '/^ *- name: OPS_COPY_HOST/ {
$!{N;s/value: \(.*\)/value: \1-copy/}
}'  $workcopy > $envpatch

cat $nocopy | sed '/^ *- env:/r '$envpatch > $docopy

cat $docopy | oc replace --force -f -
wait_for_pod_ACTION start fluentd

# Set logging-es-copy and logging-es-ops-copy to fluentd /etc/hosts for testing.
oc set env daemonset/logging-fluentd SET_ES_COPY_HOST_ALIAS=true

modcmap=`mktemp`
sed -n '{
s/^ *@include configs.d\/openshift\/output-operations.conf/    <match journal.system** system.var.log** **_default_** **_openshift_** **_openshift-infra_** mux.ops>\
     @type copy\
     @include configs.d\/dynamic\/output-es-ops-config.conf\
     @include configs.d\/user\/output-ops-extra-*.conf\
     <store>\
        @type elasticsearch_dynamic\
        host \"#{ENV['"'OPS_COPY_HOST'"']}\"\
        port \"#{ENV['"'OPS_COPY_PORT'"']}\"\
        scheme \"#{ENV['"'OPS_COPY_SCHEME'"']}\"\
        index_name .operations.${record['"'@timestamp'"'].nil? ? Time.at(time).getutc.strftime(@logstash_dateformat) : Time.parse(record['"'@timestamp'"']).getutc.strftime(@logstash_dateformat)}\
        user \"#{ENV['"'OPS_COPY_USERNAME'"']}\"\
        password \"#{ENV['"'OPS_COPY_PASSWORD'"']}\"\
        client_key \"#{ENV['"'OPS_COPY_CLIENT_KEY'"']}\"\
        client_cert \"#{ENV['"'OPS_COPY_CLIENT_CERT'"']}\"\
        ca_file \"#{ENV['"'OPS_COPY_CA'"']}\"\
        type_name com.redhat.viaq.common\
        reload_connections false\
        reload_on_failure false\
        flush_interval 5s\
        max_retry_wait 300\
        disable_retry_limit true\
        buffer_type file\
        buffer_path '"'\/var\/lib\/fluentd\/buffer-es-ops-copy-config'"'\
        buffer_queue_limit \"#{ENV['"'BUFFER_QUEUE_LIMIT'"'] || '"'1024'"' }\"\
        buffer_chunk_limit \"#{ENV['"'BUFFER_SIZE_LIMIT'"'] || '"'1m'"' }\"\
        buffer_queue_full_action \"#{ENV['"'BUFFER_QUEUE_FULL_ACTION'"'] || '"'exception'"'}\"\
        ssl_verify false\
     <\/store>\
     @include configs.d\/user\/secure-forward.conf\
    <\/match>/
s/^ *@include configs.d\/openshift\/output-applications.conf/    <match **>\
     @type copy\
     @include configs.d\/openshift\/output-es-config.conf\
     @include configs.d\/user\/output-extra-*.conf\
     <store>\
        @type elasticsearch_dynamic\
        host \"#{ENV['"'ES_COPY_HOST'"']}\"\
        port \"#{ENV['"'ES_COPY_PORT'"']}\"\
        scheme \"#{ENV['"'ES_COPY_SCHEME'"']}\"\
        index_name project.${record['"'kubernetes'"']['"'namespace_name'"']}.${record['"'kubernetes'"']['"'namespace_id'"']}.${Time.parse(record['"'@timestamp'"']).getutc.strftime(@logstash_dateformat)}\
        user \"#{ENV['"'ES_COPY_USERNAME'"']}\"\
        password \"#{ENV['"'ES_COPY_PASSWORD'"']}\"\
        client_key \"#{ENV['"'ES_COPY_CLIENT_KEY'"']}\"\
        client_cert \"#{ENV['"'ES_COPY_CLIENT_CERT'"']}\"\
        ca_file \"#{ENV['"'ES_COPY_CA'"']}\"\
        type_name com.redhat.viaq.common\
        reload_connections false\
        reload_on_failure false\
        flush_interval 5s\
        max_retry_wait 300\
        disable_retry_limit true\
        buffer_type file\
        buffer_path '"'\/var\/lib\/fluentd\/buffer-es-copy-config'"'\
        buffer_queue_limit \"#{ENV['"'BUFFER_QUEUE_LIMIT'"'] || '"'1024'"' }\"\
        buffer_chunk_limit \"#{ENV['"'BUFFER_SIZE_LIMIT'"'] || '"'1m'"' }\"\
        buffer_queue_full_action \"#{ENV['"'BUFFER_QUEUE_FULL_ACTION'"'] || '"'exception'"'}\"\
        ssl_verify false\
     <\/store>\
     @include configs.d\/user\/secure-forward.conf\
    <\/match>/
p
}' $cmap > $modcmap

cat $modcmap | oc replace --force -f -
wait_for_pod_ACTION start fluentd
rm -f $nocopy $docopy $envpatch $workcopy $modcmap

check_copy_conf true "es-copy-config.conf"
check_copy_conf true "es-ops-copy-config.conf"

# 2 sets of logs are stored to logging-es and logging-es-ops since
# 1 set is forwarded via logging-es-copy and logging-es-ops-copy
write_and_verify_logs 2 || {
    oc get events -o yaml > $ARTIFACT_DIR/all-events.yaml 2>&1
    exit 1
}

# put back original configuration
oc replace --force -f $origconfig
wait_for_pod_ACTION start fluentd
rm -f $origconfig

write_and_verify_logs 1 || {
    oc get events -o yaml > $ARTIFACT_DIR/all-events.yaml 2>&1
    exit 1
}
