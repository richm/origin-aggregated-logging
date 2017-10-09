#!/bin/bash

# Test how long it takes for logs to be read by fluentd and show
# up in elasticsearch

pushd $( dirname $0 )
scriptdir=$( pwd )
popd

source "$(dirname "${BASH_SOURCE[0]}" )/../../hack/lib/init.sh"
source "${OS_O_A_L_DIR}/hack/testing/util.sh"
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
labelstr = labelstr . sprintf("%30s: mean=%.2g min=%.2g max=%.2g stddev=%.2g\n", "'"$field"'", '$fieldvar'_mean, '$fieldvar'_min, '$fieldvar'_max, '$fieldvar'_dev)'
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
set label 1 labelstr at screen 0.2,0.99
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
    gnuplot $ARTIFACT_DIR/graph.gp
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

# note - only supports 1 host for now
# 1506020088
# host            bc ba bq bs br
# 10.128.0.136 50533  0  0  4  0
# convert to
# 1506020088 50533 0 0 4 0 bc-rate (bc(n)-bc(n-1))
process_es_bulk() {
    awk '
    NF == 1 {ts=$1}
    /^host/ {next}
    NF > 1 {if (!bcprev) {bcprev=$2}; print ts, $2, $3, $4, $5, $6, ($2-bcprev); bcprev=$2}
'
}

process_es_count() {
    awk '{if (!countprev) {countprev=$2}; print $1, $2, ($2-countprev); countprev=$2}'
}

# fluentd/mux stats are in this format now:
#        stats for es                            stats for es-ops                        stats for forward
# time_t queue_length total_queued_bytes retries queue_length total_queued_bytes retries queue_length total_queued_bytes retries
# for example
# 1505962928 1 225456 0 1 294920 0 0 0 0
# if using mux, the mux pod stats will have es (and es-ops) only, and fluentd will have
# secure_forward only (those columns will be all 0)
process_stats() {
    local file_col_field_mem_cpu_queue=""
    local file_col_field_rss_buf_emit=""
    local file_col_field_etc=""
    local file
    local comp
    local pref
    if [ -f $ARTIFACT_DIR/run_info ] ; then
        . $ARTIFACT_DIR/run_info
    fi
    for file in $ARTIFACT_DIR/logging-* ; do
        case $file in
            */logging-fluentd-*)  comp=fluentd ;;
            */logging-mux-*)      comp=mux ;;
            */logging-es-*.bulk)  comp=es ;;
            */logging-es-*.count) comp=es ;;
            *)                    continue ;;
        esac
        case $file in
            *.top.raw) datfile=$ARTIFACT_DIR/$comp.top.dat
                       cat $file | cnvt_top_fluentd_output $startts $endts > $datfile
                       file_col_field_mem_cpu_queue="$file_col_field_mem_cpu_queue $datfile 2 ${comp}-CPU% $datfile 3 ${comp}-MEM%"
                       file_col_field_rss_buf_emit="$file_col_field_rss_buf_emit $datfile 5 ${comp}-RES"
                       file_col_field_etc="$file_col_field_etc $datfile 4 ${comp}-VIRT"
                      continue ;;
            *.stats) file_col_field_rss_buf_emit="$file_col_field_rss_buf_emit $file 3 ${comp}-es-BUF-SZ $file 6 ${comp}-es-ops-BUF-SZ $file 9 ${comp}-fwd-BUF-SZ"
                     file_col_field_mem_cpu_queue="$file_col_field_mem_cpu_queue $file 2 ${comp}-es-Q-LEN $file 5 ${comp}-es-ops-Q-LEN $file 8 ${comp}-fwd-Q-LEN"
                     file_col_field_etc="$file_col_field_etc $file 4 ${comp}-es-RETRIES $file 7 ${comp}-es-ops-RETRIES $file 10 ${comp}-fwd-RETRIES"
                     continue ;;
            *.bulk) cat $file | process_es_bulk > $file.cooked
                    file_col_field_mem_cpu_queue="$file_col_field_mem_cpu_queue $file.cooked 7 ${comp}-bulk-rate"
                    continue ;;
            *.count) cat $file | process_es_count > $file.cooked
                    file_col_field_mem_cpu_queue="$file_col_field_mem_cpu_queue $file.cooked 3 ${comp}-doc-rate"
                    continue ;;
            *) continue ;;
        esac
    done
    local duration=$(( endts - startts ))
    cat <<EOF > $ARTIFACT_DIR/extra.dat
Test Duration      : $duration seconds
Start              : $startts
End                : $endts
Number of records  : $NMESSAGES
Number of projects : $NPROJECTS
Message size       : $MSGSIZE bytes
EOF
    TITLE="Fluentd/Mux RSS, Total Buffer Size, Emit Count" YLABEL="bytes/count at time" doplot $ARTIFACT_DIR/rss-buffer-emit.png $ARTIFACT_DIR/extra.dat $file_col_field_rss_buf_emit > $ARTIFACT_DIR/gnuplot.out.1 2>&1
    TITLE="Fluentd/Mux CPU%, MEM%, Queue length" YLABEL="value at time" doplot $ARTIFACT_DIR/cpu-mem-queue.png $ARTIFACT_DIR/extra.dat $file_col_field_mem_cpu_queue > $ARTIFACT_DIR/gnuplot.out.2 2>&1
    TITLE="Fluentd/Mux other stats" YLABEL="value at time" doplot $ARTIFACT_DIR/other-etc.png $ARTIFACT_DIR/extra.dat $file_col_field_etc > $ARTIFACT_DIR/gnuplot.out.3 2>&1
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
            TITLE="Mux Bulk Stats" YLABEL="value at time" doplot $ARTIFACT_DIR/mux-stats.png $ARTIFACT_DIR/extra.dat $mux_stats > $ARTIFACT_DIR/gnuplot.out.2 2>&1
        fi
    fi
}

if [ "${1:-}" = process_stats ] ; then
    process_stats
    exit 0
fi

# create a journal which has N records - output is journalctl -o export format
# suitable for piping into systemd-journal-remote
# if nproj is given, also create N records per project
format_journal() {
    local nrecs=$1
    local prefix=$2
    local msgsize=$3
    local useops=$4
    local hn=$( hostname -s )
    local startts=$( date -u +%s%6N )
    python -c 'import sys
nrecs = int(sys.argv[1])
width = len(sys.argv[1])
prefix = sys.argv[2]
msgsize = int(sys.argv[3])
useops = sys.argv[4].lower() == "true"
hn = sys.argv[5]
tsstr = sys.argv[6]
ts = int(tsstr)
pid = sys.argv[7]
if len(sys.argv) > 8:
  nproj = int(sys.argv[8])
  projwidth = len(sys.argv[8])
  contprefix = sys.argv[9]
  podprefix = sys.argv[10]
  projprefix = sys.argv[11]
  poduuid = sys.argv[12]
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
  if useops:
    sys.stdout.write(template.format(ts=ts, ii=ii) + "\n")
    ts = ts + 1
  for jj in xrange(1, nproj + 1):
    sys.stdout.write(conttemplate.format(ts=ts, ii=ii, jj=jj) + "\n")
    ts = ts + 1
' $nrecs $prefix $msgsize $useops $hn $startts $$ ${NPROJECTS:-0} ${contprefix:-""} ${podprefix:-""} ${projprefix:-""} $( uuidgen )
}

format_external_project() {
    local nrecs=$1
    local prefix=$2
    local msgsize=$3
    local hn=$( hostname -s )
    local startts=$( date -u +%s.%6N )
    python -c 'import sys,json
from datetime import datetime,timedelta
nrecs = int(sys.argv[1])
width = len(sys.argv[1])
prefix = sys.argv[2]
msgsize = int(sys.argv[3])
hn = sys.argv[4]
tsstr = sys.argv[5]
ts = datetime.fromtimestamp(float(tsstr))
usec = timedelta(microseconds=1)
msgtmpl = "{prefix}-{{ii:0{width}d}} {msg:0{msgsize}d}".format(prefix=prefix, width=width, msgsize=msgsize, msg=0)
hsh = {"hostname": hn, "level": "err", "systemd":{"u":{"SYSLOG_IDENTIFIER":prefix}}}
for ii in xrange(1, nrecs + 1):
  hsh["@timestamp"] = ts.isoformat()+"+00:00"
  hsh["message"] = msgtmpl.format(ii=ii)
  sys.stdout.write(json.dumps(hsh, indent=None, separators=(",", ":")) + "\n")
  ts = ts + usec
' $nrecs $prefix $msgsize $hn $startts
}

format_json-file_filename() {
    # $1 - $ii
    printf "%s${NPFMT}_%s${NPFMT}_%s${NPFMT}-%s.log\n" "$podprefix" $1 "$projprefix" $1 "$contprefix" $1 "`echo $1 | sha256sum | awk '{print $1}'`"
}

format_external_project_filename() {
    # $1 - $ii
    printf "%s${NPFMT}.log\n" "$projprefix" $1
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

    if [ ${USE_OPS:-true} = true -o ${USE_JOURNAL_FOR_CONTAINERS:-true} = true ] ; then
        $formatter $NMESSAGES $prefix $MSGSIZE ${USE_OPS:-true} | sysfilter
        postprocesssystemlog
    fi
    if [ ${USE_JOURNAL_FOR_CONTAINERS:-true} = false ] ; then
        while [ $ii -le $NMESSAGES ] ; do
            jj=1
            while [ $jj -le $NPROJECTS ] ; do
                if [ ${USE_JOURNAL_FOR_CONTAINERS:-true} = false ] ; then
                    fn=$( format_json-file_filename $jj )
                    format_json_message full "$NFMT" "$EXTRAFMT" "$prefix" "$ii" >> $datadir/docker/$fn
                    format_json_message short "$NFMT" "$EXTRAFMT" "$prefix" "$ii" >> $orig
                fi
                jj=`expr $jj + 1`
            done
            ii=`expr $ii + 1`
        done
    fi
    if [ "${USE_EXTERNAL_PROJECTS:-false}" = true ] ; then
        if [ ! -d $datadir/project ] ; then
            mkdir -p $datadir/project
        fi
        ii=1
        while [ $ii -le ${NPROJECTS:-0} ] ; do
            fn=$( format_external_project_filename $ii )
            format_external_project $NMESSAGES $prefix $MSGSIZE > $datadir/project/$fn
            ii=$( expr $ii + 1 )
        done
    fi
}

cleanup() {
    local result_code=$?
    set +e
    endts=${endts:-$( date +%s )}
    kill $monitor_pids
    oc logs $fpod > $ARTIFACT_DIR/$fpod.log
    { echo startts=$startts; echo endts=$endts;  echo NMESSAGES=$NMESSAGES; echo MSGSIZE=$MSGSIZE ; echo NPROJECTS=${NPROJECTS:-0}; } > $ARTIFACT_DIR/run_info
    process_stats
    if [ -n "$workdir" -a -d "$workdir" ] ; then
        rm -rf $workdir
    fi
    os::log::debug "$( oc label node --all --overwrite logging-infra-fluentd- 2>&1 )"
    os::log::debug "$( os::cmd::try_until_failure "oc get pod $fpod" )"
    if sudo test -f /var/log/journal.pos.save ; then
        sudo mv /var/log/journal.pos.save /var/log/journal.pos
    fi
    if [ -n "${fcmsave:-}" -a -f "${fcmsave:-}" ] ; then
        os::log::debug "$( oc replace --force -f $fcmsave )"
    fi
    if [ -n "${fdssave:-}" -a -f "${fdssave:-}" ] ; then
        os::log::debug "$( oc replace --force -f $fdssave )"
    fi
    if [ -n "${muxpod}" ] ; then
        if [ ${USE_MUX_DEBUG:-false} = false ] ; then
            oc logs $muxpod > $ARTIFACT_DIR/$muxpod.log
        else
            oc exec $muxpod -- cat /var/log/fluentd.log > $ARTIFACT_DIR/$muxpod.log
        fi
        if [ -n "${mcmsave:-}" -a -f "${mcmsave:-}" ] ; then
            os::log::debug "$( oc replace --force -f $mcmsave )"
        fi
        if [ -n "${mdcsave:-}" -a -f "${mdcsave:-}" ] ; then
            os::log::debug "$( oc delete dc logging-mux )"
            os::log::debug "$( os::cmd::try_until_failure "oc get dc logging-mux" )"
            os::log::debug "$( oc create -f $mdcsave )"
            os::log::debug "$( oc scale --replicas=1 dc/logging-mux )"
            os::log::debug "$( oc rollout status -w dc/logging-mux )"
        fi
    fi
    if [ ${NPROJECTS:-0} -gt 0 ] ; then
        for proj in $( seq -f "$PROJ_FMT" $NPROJECTS ) ; do
            os::log::debug "$( oc delete project $proj 2>&1 )"
            os::log::debug "$( os::cmd::try_until_failure "oc get project $proj" 2>&1 )"
        done
    fi
    os::log::debug "$( oc label node --all --overwrite logging-infra-fluentd=true 2>&1 )"
    os::log::debug "$( os::cmd::try_until_text "oc get pods -l component=fluentd" "^logging-fluentd-.* Running " )"
    # this will call declare_test_end, suite_end, etc.
    os::test::junit::reconcile_output
    exit $result_code
}
trap "cleanup" INT TERM EXIT

# set to true if running this test on an OS whose journal format
# is not compatible with el7 (e.g. fedora)
USE_CONTAINER_FOR_JOURNAL_FORMAT=${USE_CONTAINER_FOR_JOURNAL_FORMAT:-false}

# need a temp dir for log files
workdir=$( mktemp -p /var/tmp -d )
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

# create operations index/data
USE_OPS=${USE_OPS:-true}
# number of messages per project
NMESSAGES=${NMESSAGES:-300000}
# max number of digits in $NMESSAGES
NSIZE=$( printf $NMESSAGES | wc -c )
# printf format for message number
NFMT=${NFMT:-"%0${NSIZE}d"}
# total size of a record
MSGSIZE=${MSGSIZE:-599}

# set env DEBUG=true on mux pod - dump in pod to /var/log/fluentd.log
USE_MUX_DEBUG=${USE_MUX_DEBUG:-false}

os::log::info Begin fluentd to elasticsearch performance test at $( date )

if [ "${USE_JOURNAL:-true}" = "true" ] ; then
    if [ "${USE_CONTAINER_FOR_JOURNAL_FORMAT:-}" != true ] ; then
        os::log::info installing /usr/lib/systemd/systemd-journal-remote
        sudo test -x /usr/lib/systemd/systemd-journal-remote || \
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

fdssave=$ARTIFACT_DIR/f-ds-orig.yaml
oc get ds/logging-fluentd -o yaml > $fdssave
fcmsave=$ARTIFACT_DIR/f-cm-orig.yaml
oc get cm/logging-fluentd -o yaml > $fcmsave

os::log::info Configure fluentd to use test logs and redeploy . . .
# undeploy fluentd
os::log::debug "$( oc label node --all logging-infra-fluentd- )"
os::cmd::try_until_failure "oc get pod $fpod"
sudo rm -rf /var/lib/fluentd/*
# use monitor agent in mux
if [ -n "$muxpod" ] ; then
    mdcsave=$ARTIFACT_DIR/m-dc-orig.yaml
    oc get dc/logging-mux -o yaml > $mdcsave
    mcmsave=$ARTIFACT_DIR/m-cm-orig.yaml
    oc get cm/logging-mux -o yaml > $mcmsave

    muxcerts=$( oc get daemonset logging-fluentd -o yaml | egrep muxcerts ) || :

    if [ "$muxcerts" = "" ]; then
        os::log::debug "$( oc set volumes daemonset/logging-fluentd --add --overwrite \
                           --name=muxcerts --default-mode=0400 -t secret -m /etc/fluent/muxkeys --secret-name logging-mux 2>&1 )"
    fi
    oc patch -n logging dc/logging-mux --type=json --patch '[
          {"op":"remove","path":"/spec/template/spec/containers/0/resources/limits/cpu"}]'
    os::log::info Configure mux to enable monitor agent
    os::log::debug "$( oc set env dc/logging-mux ENABLE_MONITOR_AGENT=true )"
    if [ "${USE_MUX_DEBUG:-false}" = true ] ; then
        os::log::debug "$( oc set env dc/logging-mux DEBUG=$USE_MUX_DEBUG )"
    fi
    os::log::info Redeploying mux . . .
    os::log::debug "$( oc rollout status -w dc/logging-mux )"
fi
# configure fluentd to use $datadir/journal:/journal/journal as its journal source
os::log::debug "$( oc set volume daemonset/logging-fluentd --add -t hostPath --name testjournal -m /journal --path $datadir )"
os::log::debug "$( oc set env daemonset/logging-fluentd JSON_FILE_PATH="/journal/*.log" JSON_FILE_POS_FILE=/journal/es-containers.log.pos JOURNAL_SOURCE=/journal/journal JOURNAL_READ_FROM_HEAD=true ENABLE_MONITOR_AGENT=true )"
sudo mv /var/log/journal.pos /var/log/journal.pos.save
if [ "${USE_EXTERNAL_PROJECTS:-false}" = true ] ; then
    # configure fluentd to read from $datadir/project/*.log
    os::log::debug "$( oc set volume daemonset/logging-fluentd --add -t hostPath --name testexternal -m /project --path $datadir/project )"
    oc get cm logging-fluentd -o yaml | \
      sed -e '/@include configs[.]d\/openshift\/input-pre-[*][.]conf/a\
    <source>\
      @type tail\
      @label @INGRESS\
      path /project/*.log\
      tag *.test\
      pos_file /project/project.pos\
      format json\
      keep_time_key true\
      read_from_head true\
    </source>\
' | oc replace --force -f -
fi
# redeploy fluentd
os::log::debug "$( oc label node --all logging-infra-fluentd=true )"
# wait for fluentd to start
os::cmd::try_until_text "oc get pods -l component=fluentd" "^logging-fluentd-.* Running "

ARTIFACT_DIR=$ARTIFACT_DIR $scriptdir/monitor_logging.sh > $ARTIFACT_DIR/monitor_logging.out 2>&1 & monitor_pids=$!

# e.g. 100000 messages == 666 second wait time
max_wait_time=$( expr \( $NMESSAGES \* \( $NPROJECTS + 1 \) \) / 150 )

startts=$( date +%s )
fpod=$( get_running_pod fluentd )
muxpod=$( get_running_pod mux )

os::log::info Running tests . . . ARTIFACT_DIR $ARTIFACT_DIR
# measure how long it takes - wait until last record is in ES or we time out
qs='{"query":{"term":{"systemd.u.SYSLOG_IDENTIFIER":"'"${prefix}"'"}}}'
if [ $USE_OPS = true ] ; then
    os::cmd::try_until_text "curl_es ${esopspod} /.operations.*/_count -X POST -d '$qs' | get_count_from_json" ${NMESSAGES} $(( max_wait_time * second ))
fi
for proj in $( seq -f "$PROJ_FMT" $NPROJECTS ) ; do
    os::cmd::try_until_text "curl_es ${espod} /project.${proj}.*/_count -X POST -d '$qs' | get_count_from_json" ${NMESSAGES} $(( max_wait_time * second ))
done
endts=$( date +%s )
os::log::info Test run took $( expr $endts - $startts ) seconds
