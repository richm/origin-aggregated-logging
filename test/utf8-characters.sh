#!/bin/bash

# This logging test ensures that a log message containing
# extended UTF-8 characters will be correctly processed by
# Fluentd and appear in Elasticsearch.

source "$(dirname "${BASH_SOURCE[0]}" )/../hack/lib/init.sh"
source "${OS_O_A_L_DIR}/hack/testing/util.sh"
os::util::environment::use_sudo

os::test::junit::declare_suite_start "test/utf8-characters"

if [ -n "${DEBUG:-}" ] ; then
    set -x
fi

cleanup() {
    local return_code="$?"
    set +e
    if [ $return_code = 0 ] ; then
        mycmd=os::log::info
    else
        mycmd=os::log::error
    fi
    $mycmd "utf8-characters test finished at $( date )"
    # this will call declare_test_end, suite_end, etc.
    os::test::junit::reconcile_output
    exit $return_code
}
trap "cleanup" EXIT

os::log::info "Starting utf8-characters test at $( date )"

wait_for_fluentd_ready

message_uuid="$( uuidgen | sed 's/[-]//g' )"
apps_message="$(printf '%s-\xC2\xB5' "$message_uuid" )"
message_uuid="$( uuidgen | sed 's/[-]//g' )"
ops_message="$(printf '%s-\xC2\xB5' "$message_uuid" )"

get_apps_record() {
    notused=$1
    cp $2 $ARTIFACT_DIR/apps_record.json
}
get_ops_record() {
    notused=$1
    cp $2 $ARTIFACT_DIR/ops_record.json
}
APPS_MESSAGE="$es_message" OPS_MESSAGE="$es_ops_message" wait_for_fluentd_to_catch_up get_apps_record get_ops_record

os::log::info "Checking that message was successfully processed..."
os::cmd::expect_success "cat $ARTIFACT_DIR/ops_record.json | \
                         python $OS_O_A_L_DIR/hack/testing/test-utf8-characters.py '$ops_message' '$ops_message'"
