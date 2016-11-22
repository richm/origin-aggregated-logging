#!/bin/sh

set -euxo pipefail

# check required arguments

if [ -z "${MUX_HOST:-}" ] ; then
    echo Error: MUX_HOST must be specified.  This is the external FQDN by which this
    echo service will be accessed.
    exit 1
fi

MASTER_CONFIG_DIR=${MASTER_CONFIG_DIR:-/etc/origin/master}

if [ ! -d $MASTER_CONFIG_DIR ] ; then
    # test/dev env - see if we have a KUBECONFIG
    if [ -n "${KUBECONFIG:-}" ] ; then
        MASTER_CONFIG_DIR=`dirname $KUBECONFIG`
    fi
fi

if [ ! -d $MASTER_CONFIG_DIR ] ; then
    # get from openshift server ps
    # e.g.
    #    root      2477  2471 30 04:48 ?        04:03:58 /data/src/github.com/openshift/origin/_output/local/bin/linux/amd64/openshift start --loglevel=4 --logspec=*importer=5 --latest-images=false --node-config=/tmp/openshift/origin-aggregated-logging//openshift.local.config/node-192.168.78.2/node-config.yaml --master-config=/tmp/openshift/origin-aggregated-logging//openshift.local.config/master/master-config.yaml
    MASTER_CONFIG_DIR=`ps -ef|grep -v awk|awk '/openshift.*master-config=/ {print gensub(/^.*--master-config=(\/.*)\/master-config.yaml.*$/, "\\\1", 1)}'|head -1`
fi

if [ ! -d $MASTER_CONFIG_DIR/ca.key ] ; then
    echo Error: could not find the openshift ca key needed to create the mux server cert
    echo Check your permissions - you may need to run this script as root
    echo Otherwise, please specify MASTER_CONFIG_DIR correctly and re-run this script
    exit 1
fi

cacert=$MASTER_CONFIG_DIR/ca.crt
cakey=$MASTER_CONFIG_DIR/ca.key
caser=$MASTER_CONFIG_DIR/ca.serial.txt

workdir=`mktemp -d`

# generate mux server cert/key
openshift admin ca create-server-cert  \
          --key=$workdir/mux.key \
          --cert=$workdir/mux.crt \
          --hostnames=mux,$MUX_HOST \
          --signer-cert=$cacert --signer-key=$cakey --signer-serial=$caser

# generate mux shared_key
cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1 > "$workdir/mux-shared-key"

# add secret for mux
oc secrets new logging-mux \
   mux-key=$dir/mux-internal.key mux-cert=$dir/mux-internal.crt \
   mux-shared-key=$dir/mux-shared-key

# add mux secret to fluentd service account
oc secrets add serviceaccount/aggregated-logging-fluentd \
   logging-fluentd logging-mux

# generate the mux template from the fluentd template
oc get template logging-fluentd-template -o yaml > $workdir/fluentd.yaml
cp $workdir/fluentd.yaml $workdir/mux.yaml
sed -i -e s/logging-fluentd-template-maker/logging-mux-template-maker/ \
    -e "s/create template for fluentd/create template for mux/" \
    -e "s/logging-fluentd-template/logging-mux-template/" \
    -e "s/for logging fluentd deployment/for logging mux deployment/" \
    -e "s/logging-infra: fluentd/logging-infra: mux/g" \
    -e "s/component: fluentd/component: mux/" \
    -e "s,apiVersion: extensions/v1beta1

oc create route passthrough \
   --service="logging-mux" \
   --hostname="${mux_hostname}" \
   --port="mux-forward"


+function generate_mux_template(){
+  es_host=logging-es
+  es_ops_host=${es_host}
+  if [ "${input_vars[enable-ops-cluster]}" == true ]; then
+    es_ops_host=logging-es-ops
+  fi
+
+  if [ -n "${mux_forward_listen_port:-}" ] ; then
+      portparam="--param FORWARD_LISTEN_PORT=$mux_forward_listen_port"
+  else
+      portparam=
+  fi
+  create_template_optional_nodeselector "${input_vars[mux-nodeselector]}" mux \
+    --param ES_HOST=${es_host} \
+    --param OPS_HOST=${es_ops_host} \
+    --param MASTER_URL=${master_url} \
+    --param FORWARD_LISTEN_HOST=${mux_hostname} \
+    $portparam \
+    --param "$image_params"
+} #generate_fluentd_template()

+  generate_mux_template

+function generate_mux() {
+  oc new-app logging-mux-template
+}
+

+  generate_mux

# need mux pod template
# need service template
