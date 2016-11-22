#!/bin/sh

oc create route passthrough \
   --service="logging-mux" \
   --hostname="${mux_hostname}" \
   --port="mux-forward"

    # use or generate mux certs
    procure_server_cert mux       # external cert, use router cert if not present
    procure_server_cert mux-internal mux,${mux_hostname}

+    # generate mux shared_key
+    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1 > "$dir/mux-shared-key"

+    oc secrets new logging-mux \
+        mux-key=$dir/mux-internal.key mux-cert=$dir/mux-internal.crt \
+        mux-shared-key=$dir/mux-shared-key

     oc secrets add serviceaccount/aggregated-logging-fluentd \
+                   logging-fluentd logging-mux

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
