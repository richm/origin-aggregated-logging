#!/bin/sh

set -euxo pipefail

if [ -n "$OPENRC" ] ; then
    . $OPENRC
fi

scriptdir=$( dirname $0 )
oaldir=$( dirname $scriptdir )

PROPERTIES_FILE=${PROPERTIES_FILE:-${1:-$HOME/.config/openstack-properties.yaml}}
STACK_NAME=`awk '$1 == "run_stack_name:" {print $2}' $PROPERTIES_FILE`
STACK_NAME=${STACK_NAME:-$USER.oal.test}
STACK_FILE=`awk '$1 == "run_stack_file:" {print $2}' $PROPERTIES_FILE`
STACK_FILE=${STACK_FILE:-$oaldir/hack/templates/openstack-dev-machine-heat.yaml}
SERVER_NAME=`awk '$1 == "oshift_hostname:" {print $2}' $PROPERTIES_FILE`
SERVER_NAME=${SERVER_NAME:-$USER.oal.test}

if [ -z "$START_STEP" ] ; then
    echo Error: must define START_STEP
    exit 1
fi

wait_until_cmd() {
    ii=$3
    interval=${4:-10}
    while [ $ii -gt 0 ] ; do
        $1 $2 && break
        sleep $interval
        ii=`expr $ii - $interval`
    done
    if [ $ii -le 0 ] ; then
        return 1
    fi
    return 0
}

get_machine() {
    nova list | awk -v pat=$1 '$0 ~ pat {print $2}'
}

get_stack() {
    openstack stack list | awk -v pat=$1 '$0 ~ pat {print $2}'
}

cleanup_old_machine_and_stack() {
    stack=`get_stack $STACK_NAME`
    if [ -n "$stack" ] ; then
        openstack stack delete -y $stack || openstack stack delete $stack
    fi

    if [ -n "$stack" ] ; then
        wait_s_d() {
            status=`openstack stack list | awk -v ss=$1 '$0 ~ ss {print $6}'`
            if [ "$status" = "DELETE_FAILED" ] ; then
                # try again
                openstack stack delete -y $1 || openstack stack delete $stack
                return 1
            fi
            test -z "`get_stack $1`"
        }
        wait_until_cmd wait_s_d $STACK_NAME 400 20
    fi

    mach=`get_machine $SERVER_NAME`
    if [ -n "$mach" ] ; then
        nova delete $mach
    fi

    if [ -n "$mach" ] ; then
        wait_n_d() { nova show $1 > /dev/null ; }
        wait_until_cmd wait_n_d $mach 400 20
    fi
}

get_float() {
    ip=`openstack stack output show $1 instance_ip -c output_value -f value`
    if [ -n "$ip" ] ; then
        echo $ip
        return 0
    fi
    return 1
}

get_mach_status() {
    nova console-log $SERVER_NAME
}

wait_for_stack_create() {
    status=`openstack  stack list | awk -v ss=$1 '$0 ~ ss {print $6}'`
    if [ -z "${status:-}" ] ; then
        return 1 # not created yet
    elif [ $status = "CREATE_IN_PROGRESS" ] ; then
        return 1
    elif [ $status = "CREATE_COMPLETE" ] ; then
        return 0
    elif [ $status = "CREATE_FAILED" ] ; then
        echo could not create stack
        openstack stack show $STACK_NAME
        exit 1
    else
        echo unknown stack create status $status
        return 1
    fi
    return 0
}

create_stack_and_mach_get_float_ip() {
    openstack stack create -e $PROPERTIES_FILE \
              --parameter oshift_hostname=$SERVER_NAME \
              -t $STACK_FILE $STACK_NAME

    wait_until_cmd wait_for_stack_create $STACK_NAME 300

    stack=`get_stack $STACK_NAME`
    wait_until_cmd get_float $stack 400
}

if [ "$START_STEP" = clean ] ; then
    cleanup_old_machine_and_stack
    START_STEP=create
fi

ip=
stack=
if [ "$START_STEP" = create ] ; then
    create_stack_and_mach_get_float_ip
    if [ -z "$stack" ] ; then
        stack=`get_stack $STACK_NAME`
    fi
    ip=`get_float $stack`
fi
echo machine ip is $ip - ssh fedora@$ip
