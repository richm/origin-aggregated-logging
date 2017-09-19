#!/bin/bash

# Test how long it takes for logs to be read by fluentd and show
# up in elasticsearch

source "$(dirname "${BASH_SOURCE[0]}" )/../../hack/lib/init.sh"
source "${OS_O_A_L_DIR}/deployer/scripts/util.sh"
os::util::environment::use_sudo

os::test::junit::declare_suite_start "test/perf-fluent-to-es"

if [ -n "${DEBUG:-}" ] ; then
    curl_output() {
        python -mjson.tool
    }
    yum_output() {
        cat
    }
else
    curl_output() {
        cat > /dev/null 2>&1
    }
    yum_output() { curl_output ; }
fi

GPFONT=/usr/share/fonts/default/Type1/n022003l.pfb
if [ -f /usr/share/fonts/liberation/LiberationSans-Regular.ttf ] ; then
    GPFONT=/usr/share/fonts/liberation/LiberationSans-Regular.ttf
fi

XLABEL=${XLABEL:-"Time"}
gnuplotheader='
set terminal png font "'$GPFONT'" 12 size 1700,1800
set xlabel "'"$XLABEL"'"
set xdata time
set timefmt "%s"
set format x "%H:%M:%S"
set grid'

doplot() {
    local graphout=$1 ; shift
    local extradat=$1 ; shift
    DELIM=${DELIM:-" "}
    if [ -n "${AUTOTITLE:-}" ] ; then
        AUTOTITLE="set key autotitle columnhead"
    fi
    TITLE=${TITLE:-"Ops/Second by Time"}
    YLABEL=${YLABEL:-"ops/sec"}
    local gpstr="plot"
    local gpnext=""
    local ii=1
    while [ -n "${1:-}" ] ; do
        local gpoutf=$1 ; shift
        local col=$1 ; shift
        local field="$1" ; shift
        local fieldvar="field$ii"
        gpstr="${gpstr}$gpnext "'"'$gpoutf'" using 1:'$col' title "'"$field"'" with lines'
        gpnext=", "
        # get stats
        local statstr="${statstr:-}"'
plot "'$gpoutf'" u 1:'$col'
'$fieldvar'_min = GPVAL_DATA_Y_MIN
'$fieldvar'_max = GPVAL_DATA_Y_MAX
f(x) = '$fieldvar'_mean
fit f(x) "'$gpoutf'" u 1:'$col' via '$fieldvar'_mean
if (exists("FIT_WSSR")&&exists("FIT_NDF")) '$fieldvar'_dev = sqrt(FIT_WSSR / (FIT_NDF + 1 ))
if (!exists("FIT_WSSR")||!exists("FIT_NDF")) '$fieldvar'_dev = 0.0
labelstr = labelstr . sprintf("%s: mean=%g min=%g max=%g stddev=%g\n", "'"$field"'", '$fieldvar'_mean, '$fieldvar'_min, '$fieldvar'_max, '$fieldvar'_dev)'
        ii=`expr $ii + 1`
    done

    # output of fit command goes to stderr - no way to turn it off :P
    cat <<EOF > $ARTIFACT_DIR/graph.gp
extradat = system("cat $extradat")
set fit logfile "/dev/null"
set terminal unknown
labelstr = ""
$statstr
$gnuplotheader
${AUTOTITLE:-}
set datafile separator "$DELIM"
set label 1 labelstr at screen 0.4,0.99
set label 2 extradat at screen 0.01,0.99
set key at screen 1.0,1.0
set output "$graphout"
set title "$TITLE"
set ylabel "$YLABEL (linear)"
set multiplot
set size 1.0,0.45
set origin 0.0,0.45
set mytics 2
$gpstr
unset label 1
unset label 2
unset title
set mytics default
set size 1.0,0.45
set origin 0.0,0.0
set logscale y
set ylabel "$YLABEL (logarithmic)"
replot
unset multiplot
EOF
    gnuplot $ARTIFACT_DIR/graph.gp > $ARTIFACT_DIR/gnuplot.log 2>&1
}

# convert something that looks like this:
# top - 22:35:10 up 11:34,  0 users,  load average: 0.52, 0.21, 0.16
# Tasks:   8 total,   1 running,   7 sleeping,   0 stopped,   0 zombie
# %Cpu(s):  9.1 us,  3.5 sy,  0.0 ni, 85.9 id,  1.3 wa,  0.0 hi,  0.1 si,  0.2 st
# KiB Mem : 16004804 total,   692784 free,  3649172 used, 11662848 buff/cache
# KiB Swap:        0 total,        0 free,        0 used. 10371544 avail Mem

#   PID USER      PR  NI    VIRT    RES    SHR S  %CPU %MEM     TIME+ COMMAND
#     1 root      20   0  119124  23224   4452 S   0.0  0.1   0:00.52 fluentd
#    35 root      20   0  763212 112504   4404 S   0.0  0.7  14:44.69 fluentd
# to something that looks like this:
# 1500397189 0.0 0.7 763212 112504
# where column 1 is time_t, 2 is cpu%, 3 is mem%, 4 is VIRT, and 5 is RES
# top date is local time, assume running this on the same machine, convert
# to UTC - also assumes running on same day since top doesn't have day
cnvt_top_fluentd_output() {
    awk -v hroff=0 -v secoff=0 -v startts=$1 -v endts=${2:-2147483648} -F '[ :]*' '
    BEGIN { yr = strftime("%Y", startts) ; mon = strftime("%m", startts) ; day = strftime("%d", startts) }
    /^top/ {
        origts=$3 ":" $4 ":" $5
        ts=mktime(yr " " mon " " day " " $3 " " $4 " " $5)+(hroff*3600)+secoff
        # diff=ts - startts
        # hrs=diff/3600
        # print "ts diff is " diff " hrs " hrs
    }
    (ts >= startts) && (ts <= endts) && ($14 == "fluentd") && ($2 != "1") {
        print ts, $10, $11, $6*1000, $7*1000
    }
'
}

process_stats() {
    local file_col_field_mem_cpu_other=""
    local file_col_field_buf_virt_res=""
    local file
    local comp
    local pref
    for file in $ARTIFACT_DIR/logging-* ; do
        case $file in
            */logging-fluentd-*) comp=fluentd ;;
            */logging-mux-*) comp=mux ;;
            *) continue ;;
        esac
        case $file in
            *.top.raw) datfile=$ARTIFACT_DIR/$comp.top.dat
                       cat $file | cnvt_top_fluentd_output $startts $endts > $datfile
                       file_col_field_mem_cpu_other="$file_col_field_mem_cpu_other $datfile 2 ${comp}-CPU% $datfile 3 ${comp}-MEM%"
                        file_col_field_buf_virt_res="$file_col_field_buf_virt_res $datfile 4 ${comp}-VIRT $datfile 5 ${comp}-RES"
                      continue ;;
            *logging-mux-*.log) muxlog=$file ; continue ;;
            *-es.stats) pref=${comp}-es ;;
            *-es-ops.stats) pref=${comp}-es-ops ;;
            *-forward.stats) pref=${comp}-forward ;;
        esac
        file_col_field_buf_virt_res="$file_col_field_buf_virt_res $file 4 ${pref}-BUF-SZ"
        file_col_field_mem_cpu_other="$file_col_field_mem_cpu_other $file 2 ${pref}-DUR $file 3 ${pref}-Q-LEN $file 5 ${pref}-RETRIES"
    done
    local duration=$(( endts - startts ))
    cat <<EOF > $ARTIFACT_DIR/extra.dat
Test Duration $duration seconds Start $startts End $endts
Number of records: $NMESSAGES    Message size: $MSGSIZE
EOF
    TITLE="Fluentd/Mux Memory Sizes in bytes" YLABEL="bytes at time" doplot $ARTIFACT_DIR/memory-sizes.png $ARTIFACT_DIR/extra.dat $file_col_field_buf_virt_res
    TITLE="Fluentd/Mux CPU%, MEM%, etc." YLABEL="value at time" doplot $ARTIFACT_DIR/cpu-mem-other.png $ARTIFACT_DIR/extra.dat $file_col_field_mem_cpu_other
    if [ -n "${muxlog:-}" ] ; then
        awk '/sent message.*logging-es:9200/ {print $12, $14, $16, $18}' $muxlog > $ARTIFACT_DIR/mux-es.stats
        awk '/sent message.*logging-es-ops:9200/ {print $12, $14, $16, $18}' $muxlog > $ARTIFACT_DIR/mux-es-ops.stats
        mux_stats=""
        if [ -s $ARTIFACT_DIR/mux-es.stats ] ; then
            mux_stats="$mux_stats $ARTIFACT_DIR/mux-es.stats 2 ES-DUR $ARTIFACT_DIR/mux-es.stats 3 ES-BYTES $ARTIFACT_DIR/mux-es.stats 4 ES-NRECS"
        fi
        if [ -s $ARTIFACT_DIR/mux-es-ops.stats ] ; then
            mux_stats="$mux_stats $ARTIFACT_DIR/mux-es-ops.stats 2 ES-OPS-DUR $ARTIFACT_DIR/mux-es-ops.stats 3 ES-OPS-BYTES $ARTIFACT_DIR/mux-es.stats 4 ES-OPS-NRECS"
        fi
        if [ -n "$mux_stats" ] ; then
            TITLE="Mux Bulk Stats" YLABEL="value at time" doplot $ARTIFACT_DIR/mux-stats.png $ARTIFACT_DIR/extra.dat $mux_stats
        fi
    fi
}

# create a journal which has N records - output is journalctl -o export format
# suitable for piping into systemd-journal-remote
# if nproj is given, also create N records per project
format_journal() {
    local nrecs=$1
    local prefix=$2
    local msgsize=$3
    local hn=$( hostname -s )
    local startts=$( date -u +%s%6N )
    python -c 'import sys
nrecs = int(sys.argv[1])
width = len(sys.argv[1])
prefix = sys.argv[2]
msgsize = int(sys.argv[3])
hn = sys.argv[4]
tsstr = sys.argv[5]
ts = int(tsstr)
pid = sys.argv[6]
if len(sys.argv) > 7:
  nproj = int(sys.argv[7])
  projwidth = len(sys.argv[7])
  contprefix = sys.argv[8]
  podprefix = sys.argv[9]
  projprefix = sys.argv[10]
  poduuid = sys.argv[11]
  contfields = """CONTAINER_NAME=k8s_{contprefix}{{jj:0{projwidth}d}}.deadbeef_{podprefix}{{jj:0{projwidth}d}}_{projprefix}{{jj:0{projwidth}d}}_{poduuid}_abcdef01
CONTAINER_ID={xx}
CONTAINER_ID_FULL={yy}
""".format(contprefix=contprefix,projwidth=projwidth,podprefix=podprefix,projprefix=projprefix,poduuid=poduuid,xx="1"*12,yy="1"*64)
else:
  nproj = 0
  contfields = ""

template = """_SOURCE_REALTIME_TIMESTAMP={{ts}}
__REALTIME_TIMESTAMP={{ts}}
_BOOT_ID=0937011437e44850b3cb5a615345b50f
_UID=1000
_GID=1000
_HOSTNAME={hn}
SYSLOG_IDENTIFIER={prefix}
SYSLOG_FACILITY=1
_COMM={prefix}
_PID={pid}
_TRANSPORT=stderr
PRIORITY=3
UNKNOWN1=1
UNKNOWN2=2
""".format(prefix=prefix, hn=hn, width=width, pid=pid,contfields=contfields)

padlen = msgsize - (len(template) + 2*len(tsstr) + len(prefix) + width + 1 + 1)
template = template + """MESSAGE={prefix}-{{ii:0{width}d}} {msg:0{padlen}d}
""".format(prefix=prefix, width=width, padlen=padlen, msg=0)

conttemplate = template + contfields

for ii in xrange(1, nrecs + 1):
  sys.stdout.write(template.format(ts=ts, ii=ii) + "\n")
  ts = ts + 1
  for jj in xrange(1, nproj + 1):
    sys.stdout.write(conttemplate.format(ts=ts, ii=ii, jj=jj) + "\n")
    ts = ts + 1
' $nrecs $prefix $msgsize $hn $startts $$ ${NPROJECTS:-0} ${contprefix:-""} ${podprefix:-""} ${projprefix:-""} $( uuidgen )
}

format_json_filename() {
    # $1 - $ii
    printf "%s${NPFMT}_%s${NPFMT}_%s${NPFMT}-%s.log\n" "$podprefix" $1 "$projprefix" $1 "$contprefix" $1 "`echo $1 | sha256sum | awk '{print $1}'`"
}

# CONTAINER_NAME=k8s_bob.94e110c7_bob-iq0d4_default_2d67916a-1eac-11e6-94ba-001c42e13e5d_8b4b7e3d
# From this, we can extract:
#    container name in pod: bob
#    pod name: bob-iq0d4
#    namespace: default
#    pod uid: 2d67916a-1eac-11e6-94ba-001c42e13e5d
get_journal_container_name() {
    printf "k8s_%s${NPFMT}.deadbeef_%s${NPFMT}_%s${NPFMT}_%s_abcdef01\n" "$contprefix" $1 "$podprefix" $1 "$projprefix" $1 `uuidgen`
}

create_test_log_files() {
    ii=1
    prefix=$( uuidgen )
    # need $MSGSIZE - (36 + "-" + $NSIZE + " ") bytes
    n=$( expr $MSGSIZE - 36 - 1 - $NSIZE - 1 )
    EXTRAFMT=${EXTRAFMT:-"%0${n}d"}
    if [ "${USE_JOURNAL:-true}" = "true" ] ; then
        formatter=format_journal
        if [ "${USE_CONTAINER_FOR_JOURNAL_FORMAT:-}" = true ] ; then
            sysfilter() {
                cat >> $datadir/journalinput.txt
            }
            postprocesssystemlog() {
                docker build -t viaq/journal-maker:latest journal-maker
                docker run --privileged -u 0 -e INPUTFILE=/var/log/journalinput.txt -e OUTPUTFILE=/var/log/journal/messages.journal -v $datadir:/var/log viaq/journal-maker:latest
                sudo chown -R ${USER}:${USER} $datadir/journal
            }
        else
            sysfilter() {
                os::log::debug "$( /usr/lib/systemd/systemd-journal-remote - -o $systemlog 2>&1 )"
            }
            postprocesssystemlog() {
                :
            }
        fi
    else
        formatter=format_syslog_message
        sysfilter() {
            cat >> $systemlog
        }
        postprocesssystemlog() {
            :
        }
    fi

    $formatter $NMESSAGES $prefix $MSGSIZE | sysfilter
    postprocesssystemlog
    if [ ${USE_JOURNAL_FOR_CONTAINERS:-true} = false ] ; then
        if [ $NPROJECTS -gt 0 ] ; then
            while [ $ii -le $NMESSAGES ] ; do
                jj=1
                while [ $jj -le $NPROJECTS ] ; do
                    if [ ${USE_JOURNAL_FOR_CONTAINERS:-true} = false ] ; then
                        fn=$( format_json_filename $jj )
                        format_json_message full "$NFMT" "$EXTRAFMT" "$prefix" "$ii" >> $datadir/docker/$fn
                        format_json_message short "$NFMT" "$EXTRAFMT" "$prefix" "$ii" >> $orig
                    fi
                    jj=`expr $jj + 1`
                done
                ii=`expr $ii + 1`
            done
        fi
    fi
}

monitor_pids=""

run_top_on_pod() {
    stdbuf -o 0 oc exec $1 -- top -b -d 1 > $ARTIFACT_DIR/$1.top.raw & monitor_pids="$monitor_pids $!"
}

get_secure_forward_plugin_id() {
    oc exec $1 -- curl -s http://localhost:24220/api/plugins.json | \
        python -c 'import sys,json; print [xx["plugin_id"] for xx in json.load(sys.stdin)["plugins"] if xx.get("type") == "secure_forward"][0]'
}

get_es_plugin_id() {
    oc exec $1 -- curl -s http://localhost:24220/api/plugins.json | \
        python -c 'import sys,json
hsh = json.load(sys.stdin)["plugins"]
matches = [xx["plugin_id"] for xx in hsh if -1 < xx["config"].get("buffer_path", "").find("output-es-config")]
if not matches:
   matches = [xx["plugin_id"] for xx in hsh if xx["config"].get("host") == "logging-es"]
if matches:
  print matches[0]
else:
  print "Error: es_plugin_id not found"
'
}

get_es_ops_plugin_id() {
    oc exec $1 -- curl -s http://localhost:24220/api/plugins.json | \
        python -c 'import sys,json
hsh = json.load(sys.stdin)["plugins"]
matches = [xx["plugin_id"] for xx in hsh if -1 < xx["config"].get("buffer_path", "").find("output-es-ops-config")]
if not matches:
   matches = [xx["plugin_id"] for xx in hsh if xx["config"].get("host") == "logging-es-ops"]
if matches:
  print matches[0]
else:
  print "Error: es_ops_plugin_id not found"
'
}

# if using mux, grab the secure_forward output plugin from fluentd, and grab
# the mux es output plugins
# if not using mux, grab the fluentd es output plugins
# richm 20170717 - /api/plugins.json?@type=name isn't working - have to parse the full json
#                  output to get the plugin id, then ?@id=$id works
setup_fluentd_monitors() {
    fluentd_monitors=""
    if [ -n "${muxpod:-}" ] ; then
        os::cmd::try_until_success "get_secure_forward_plugin_id $fpod"
        secure_forward_plugin_id=$( get_secure_forward_plugin_id $fpod )
        os::cmd::try_until_success "get_es_ops_plugin_id $muxpod"
        es_ops_plugin_id=$( get_es_ops_plugin_id $muxpod )
        os::cmd::try_until_success "get_es_plugin_id $muxpod"
        es_plugin_id=$( get_es_plugin_id $muxpod )
        fluentd_monitors="$fpod $secure_forward_plugin_id get_fluentd_monitor_sf_stats forward $muxpod $es_ops_plugin_id get_fluentd_monitor_es_stats es-ops $muxpod $es_plugin_id get_fluentd_monitor_es_stats es"
    else
        os::cmd::try_until_success "get_es_ops_plugin_id $fpod"
        es_ops_plugin_id=$( get_es_ops_plugin_id $fpod )
        os::cmd::try_until_success "get_es_plugin_id $fpod"
        es_plugin_id=$( get_es_plugin_id $fpod )
        fluentd_monitors="$fpod $es_ops_plugin_id get_fluentd_monitor_es_stats es-ops $fpod $es_plugin_id get_fluentd_monitor_es_stats es"
    fi
}

# why get starts and endts?  because when fluentd is heavily loaded the
# monitor endpoint may not respond for several seconds - so we need to
# capture this information too
get_fluentd_monitor_sf_stats() {
    oc exec $1 -- curl -s http://localhost:24220/api/plugins.json\?@id=$2 | \
        python -c 'import sys,json,time; startts=int(sys.argv[1]); hsh=json.load(sys.stdin)["plugins"][0]; print "{startts} {duration} {bql} {btqs} {retry_count}".format(startts=startts, duration=int(time.time())-startts, bql=hsh["buffer_queue_length"], btqs=hsh["buffer_total_queued_size"], retry_count=hsh["retry_count"])' $( date -u +%s )
}

get_fluentd_monitor_es_stats() {
    oc exec $1 -- curl -s http://localhost:24220/api/plugins.json\?@id=$2\&debug=true | \
        python -c 'import sys,json,time; startts=int(sys.argv[1]); hsh=json.load(sys.stdin)["plugins"][0]; print "{startts} {duration} {bql} {btqs} {retry_count} {next_flush_time} {last_retry_time} {next_retry_time} {emit_count}".format(startts=startts, duration=int(time.time())-startts, bql=hsh["buffer_queue_length"], btqs=hsh["buffer_total_queued_size"], retry_count=hsh["retry_count"], next_flush_time=hsh["instance_variables"]["next_flush_time"], last_retry_time=hsh["instance_variables"]["last_retry_time"], next_retry_time=hsh["instance_variables"]["next_retry_time"], emit_count=hsh["instance_variables"]["emit_count"])' $( date -u +%s )
}

get_all_fluentd_monitor_stats() {
    set -- $fluentd_monitors
    while [ -n "${1:-}" ] ; do
        local pod=$1; shift
        local id=$1; shift
        local func=$1; shift
        local name=$1; shift
        while true ; do
            $func $pod $id
            sleep 1
        done > $ARTIFACT_DIR/$pod.fluentd-$name.stats 2>&1 & monitor_pids="$monitor_pids $!"
    done
}

# set to true if running this test on an OS whose journal format
# is not compatible with el7 (e.g. fedora)
USE_CONTAINER_FOR_JOURNAL_FORMAT=false

# need a temp dir for log files
workdir=`mktemp -p /var/tmp -d`
mkdir -p $workdir
confdir=$workdir/config
datadir=$workdir/data
orig=$workdir/orig
result=$workdir/result
if [ "${USE_JOURNAL:-true}" = "true" ] ; then
    mkdir -p $datadir/journal
    systemlog=$datadir/journal/messages.journal
else
    systemlog=$datadir/messages
fi
# number of projects, number size, printf format
NPROJECTS=${NPROJECTS:-1}
NPSIZE=$( printf $NPROJECTS | wc -c )
NPFMT=${NPFMT:-"%0${NPSIZE}d"}
podprefix="this-is-pod-"
projprefix="this-is-project-"
contprefix="this-is-container-"
# for the seq -f argument
PROJ_FMT="${projprefix}%0${NPSIZE}.f"

# number of messages per project
NMESSAGES=${NMESSAGES:-50000}
# max number of digits in $NMESSAGES
NSIZE=$( printf $NMESSAGES | wc -c )
# printf format for message number
NFMT=${NFMT:-"%0${NSIZE}d"}
# total size of a record
MSGSIZE=${MSGSIZE:-599}

cleanup() {
    local result_code=$?
    set +e
    endts=${endts:-$( date +%s )}
    kill $monitor_pids
    oc logs $fpod > $ARTIFACT_DIR/$fpod.log
    if [ -n "${muxpod}" ] ; then
        oc logs $muxpod > $ARTIFACT_DIR/$muxpod.log
    fi
    process_stats
    if [ -n "$workdir" -a -d "$workdir" ] ; then
        rm -rf $workdir
    fi
    os::log::debug "$( oc label node --all logging-infra-fluentd- )"
    os::cmd::try_until_failure "oc get pod $fpod"
    if [ -f /var/log/journal.pos.save ] ; then
        mv /var/log/journal.pos.save /var/log/journal.pos
    fi
    os::log::debug "$( oc set volume daemonset/logging-fluentd --remove --name testjournal )"
    os::log::debug "$( oc set env daemonset/logging-fluentd JOURNAL_SOURCE- JOURNAL_READ_FROM_HEAD- )"
    os::log::debug "$( oc label node --all logging-infra-fluentd=true )"
    if [ ${NPROJECTS:-0} -gt 0 ] ; then
        for proj in $( seq -f "$PROJ_FMT" $NPROJECTS ) ; do
            os::log::debug "$( oc delete project $proj )"
        done
    fi
    # this will call declare_test_end, suite_end, etc.
    os::test::junit::reconcile_output
    exit $result_code
}
trap "cleanup" INT TERM EXIT

os::log::info Begin fluentd to elasticsearch performance test at $( date )

if [ "${USE_JOURNAL:-true}" = "true" ] ; then
    if [ "${USE_CONTAINER_FOR_JOURNAL_FORMAT:-}" != true ] ; then
        os::log::info installing /usr/lib/systemd/systemd-journal-remote
        test -x /usr/lib/systemd/systemd-journal-remote || \
            sudo yum -y install /usr/lib/systemd/systemd-journal-remote 2>&1 | yum_output || \
            sudo dnf -y install /usr/lib/systemd/systemd-journal-remote 2>&1 | yum_output || {
                os::log::error please install the package containing /usr/lib/systemd/systemd-journal-remote
                exit 1
            }
    fi
fi

if [ ${NPROJECTS:-0} -gt 0 ] ; then
    os::log::info Creating $NPROJECTS projects/namespaces
    for proj in $( seq -f "$PROJ_FMT" $NPROJECTS ) ; do
        os::log::debug "$( oadm new-project $proj --node-selector='' )"
    done
fi

os::log::info create_test_log_files . . .
create_test_log_files

espod=$( get_running_pod es )
esopspod=$( get_running_pod es-ops )
esopspod=${esopspod:-$espod}

fpod=$( get_running_pod fluentd )
muxpod=$( get_running_pod mux )
# use monitor agent in mux
if [ -n "$muxpod" ] ; then
    os::log::info Configure mux to enable monitor agent
    os::log::debug "$( oc set env dc/logging-mux ENABLE_MONITOR_AGENT=true )"
    os::log::info Redeploying mux . . .
    os::log::debug "$( oc rollout status -w dc/logging-mux )"
fi

os::log::info Configure fluentd to use test logs and redeploy . . .
# undeploy fluentd
os::log::debug "$( oc label node --all logging-infra-fluentd- )"
os::cmd::try_until_failure "oc get pod $fpod"
# configure fluentd to use $datadir/journal:/journal/journal as its journal source
os::log::debug "$( oc set volume daemonset/logging-fluentd --add -t hostPath --name testjournal -m /journal --path $datadir )"
os::log::debug "$( oc set env daemonset/logging-fluentd JOURNAL_SOURCE=/journal/journal JOURNAL_READ_FROM_HEAD=true ENABLE_MONITOR_AGENT=true )"
mv /var/log/journal.pos /var/log/journal.pos.save
# redeploy fluentd
os::log::debug "$( oc label node --all logging-infra-fluentd=true )"
# wait for fluentd to start
os::cmd::try_until_text "oc get pods -l component=fluentd" "^logging-fluentd-.* Running "

# e.g. 100000 messages == 666 second wait time
max_wait_time=$( expr \( $NMESSAGES \* \( $NPROJECTS + 1 \) \) / 150 )

startts=$( date +%s )
# get running pods to monitor
fpod=$( get_running_pod fluentd )
run_top_on_pod $fpod
muxpod=$( get_running_pod mux )
if [ -n "${muxpod:-}" ] ; then
    run_top_on_pod $muxpod
fi
setup_fluentd_monitors
get_all_fluentd_monitor_stats

os::log::info Running tests . . . ARTIFACT_DIR $ARTIFACT_DIR
# measure how long it takes - wait until last record is in ES or we time out
qs='{"query":{"term":{"systemd.u.SYSLOG_IDENTIFIER":"'"${prefix}"'"}}}'
os::cmd::try_until_text "curl_es ${esopspod} /.operations.*/_count -X POST -d '$qs' | get_count_from_json" ${NMESSAGES} $(( max_wait_time * second ))
for proj in $( seq -f "$PROJ_FMT" $NPROJECTS ) ; do
    os::cmd::try_until_text "curl_es ${espod} /project.${proj}.*/_count -X POST -d '$qs' | get_count_from_json" ${NMESSAGES} $(( max_wait_time * second ))
done
endts=$( date +%s )
os::log::info Test run took $( expr $endts - $startts ) seconds
