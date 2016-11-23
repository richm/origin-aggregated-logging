#!/bin/sh

set -eux

# check required arguments

if [ -z "${MUX_HOST:-}" ] ; then
    echo Error: MUX_HOST must be specified.  This is the external FQDN by which this
    echo service will be accessed.
    exit 1
fi

FORWARD_LISTEN_PORT=${FORWARD_LISTEN_PORT:-24284}

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

if [ ! -f $MASTER_CONFIG_DIR/ca.key ] ; then
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

oc delete -n logging dc logging-mux || :
oc delete -n logging secret logging-mux || :
oc delete -n logging configmap logging-mux || :
oc delete -n logging service logging-mux || :
oc delete -n logging route logging-mux || :

# add secret for mux
oc secrets -n logging new logging-mux \
   mux-key=$workdir/mux.key mux-cert=$workdir/mux.crt \
   mux-shared-key=$workdir/mux-shared-key mux-ca=$cacert

# add mux secret to fluentd service account
oc secrets -n logging add serviceaccount/aggregated-logging-fluentd \
   logging-fluentd logging-mux

# create our configmap files
cat > $workdir/fluent.conf <<EOF
@include configs.d/openshift/system.conf
@include configs.d/openshift/input-pre-*.conf
@include configs.d/user/forward.conf
@include configs.d/openshift/input-post-*.conf
##
<label @INGRESS>
## filters
  @include configs.d/openshift/filter-pre-*.conf
  @include configs.d/openshift/filter-retag-journal.conf
  <filter journal.system>
    @type stdout
  </filter>
  @include configs.d/openshift/filter-k8s-meta.conf
  @include configs.d/openshift/filter-kibana-transform.conf
  @include configs.d/openshift/filter-k8s-record-transform.conf
  @include configs.d/openshift/filter-syslog-record-transform.conf
  @include configs.d/openshift/filter-common-data-model.conf
  @include configs.d/openshift/filter-post-*.conf
##

## matches
  @include configs.d/openshift/output-pre-*.conf
  @include configs.d/openshift/output-operations.conf
  @include configs.d/openshift/output-applications.conf
  # no post - applications.conf matches everything left
##
</label>
EOF

cat > $workdir/forward.conf <<EOF
<source>
  @type secure_forward
  @label @INGRESS
  port "#{ENV['FORWARD_LISTEN_PORT'] || '24284'}"
  # bind 0.0.0.0 # default
  log_level "#{ENV['FORWARD_INPUT_LOG_LEVEL'] || ENV['LOG_LEVEL'] || 'warn'}"
  self_hostname "#{ENV['FORWARD_LISTEN_HOST'] || 'mux.example.com'}"
  shared_key    "#{File.open('/etc/fluent/muxkeys/mux-shared-key') do |f| f.readline end.rstrip}"
  secure yes
  cert_path        /etc/fluent/muxkeys/mux-cert
  private_key_path /etc/fluent/muxkeys/mux-key
  private_key_passphrase not_used_key_is_unencrypted
</source>
EOF

# generate fluentd configmap
oc create -n logging configmap logging-mux \
   --from-file=fluent.conf=$workdir/fluent.conf \
   --from-file=forward.conf=$workdir/forward.conf
oc label configmap/logging-mux logging-infra=support

# generate the mux template from the fluentd template
oc get -n logging template logging-fluentd-template -o yaml > $workdir/fluentd.yaml

# create snippet files that we can insert with sed
cat > $workdir/1 <<EOF
    replicas: 1
    selector:
      component: mux
      provider: openshift
    strategy:
      resources: {}
      rollingParams:
        intervalSeconds: 1
        timeoutSeconds: 600
        updatePeriodSeconds: 1
      type: Rolling
    template:
EOF

cat > $workdir/2 <<EOF
          ports:
          - containerPort: \${FORWARD_LISTEN_PORT}
            name: mux-forward
          volumeMounts:
          - mountPath: /etc/fluent/configs.d/user
            name: config
            readOnly: true
          - mountPath: /etc/fluent/keys
            name: certs
            readOnly: true
          - name: muxcerts
            mountPath: /etc/fluent/muxkeys
            readOnly: true
EOF

cat > $workdir/3 <<EOF
        volumes:
        - configMap:
            name: logging-mux
          name: config
        - name: certs
          secret:
            secretName: logging-fluentd
        - name: muxcerts
          secret:
            secretName: logging-mux
EOF

cat > $workdir/4 <<EOF
-
  description: 'The external hostname used to connect to the forward listener.'
  name: FORWARD_LISTEN_HOST
  value: "mux.example.com"
-
  description: 'The default port the forward listener uses for incoming connections (targetPort: mux-forward).'
  name: FORWARD_LISTEN_PORT
  value: "24284"
EOF

cat > $workdir/5 <<EOF
          - name: FORWARD_LISTEN_HOST
            value: \${FORWARD_LISTEN_HOST}
          - name: FORWARD_LISTEN_PORT
            value: \${FORWARD_LISTEN_PORT}
EOF

cp $workdir/fluentd.yaml $workdir/mux.yaml
sed -i -e s/logging-fluentd-template-maker/logging-mux-template-maker/ \
    -e "s/create template for fluentd/create template for mux/" \
    -e "s/logging-fluentd-template/logging-mux-template/" \
    -e "s/for logging fluentd deployment/for logging mux deployment/" \
    -e "s/logging-infra: fluentd/logging-infra: mux/g" \
    -e "s/component: fluentd/component: mux/" \
    -e "s,apiVersion: extensions/v1beta1,apiVersion: v1," \
    -e 's/kind: "DaemonSet"/kind: "DeploymentConfig"/' \
    -e 's/kind: DaemonSet/kind: DeploymentConfig/' \
    -e 's/component: fluentd/component: mux/' \
    -e 's/name: logging-fluentd/name: logging-mux/' \
    -e "s/name: fluentd-elasticsearch/name: mux/" \
    -e "/^    selector:/,/^    template:/d" \
    -e "/^  spec:/r $workdir/1" \
    -e "/^          volumeMounts:/,/^        nodeSelector:/c\        nodeSelector:" \
    -e "/^          securityContext:/,/^            privileged: true/d" \
    -e "/^          imagePullPolicy: Always/r $workdir/2" \
    -e "/^        volumes:/,/^    updateStrategy:/c\    updateStrategy:" \
    -e "/^        terminationGracePeriodSeconds:/r $workdir/3" \
    -e "/^parameters:/r $workdir/4" \
    -e "/^        - env:/r $workdir/5" \
    $workdir/mux.yaml

oc new-app -n logging --param=FORWARD_LISTEN_HOST=$MUX_HOST -f $workdir/mux.yaml

cat <<EOF | oc create -f -
apiVersion: v1
kind: Service
metadata:
  name: logging-mux
spec:
  ports:
    -
      port: ${FORWARD_LISTEN_PORT}
      targetPort: mux-forward
      name: mux-forward
  selector:
    provider: openshift
    component: mux
EOF
# this doesn't work - not sure why
#oc create -n logging service clusterip logging-mux --tcp=$FORWARD_LISTEN_PORT:mux-forward

oc create -n logging route passthrough --service="logging-mux" \
   --hostname="$MUX_HOST" --port="mux-forward"
