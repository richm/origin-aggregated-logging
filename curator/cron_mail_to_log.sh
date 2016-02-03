#!/bin/sh
# convert the output of crond mail to a logging format
# crond email looks like this:
###
# From: "(Cron Daemon)" <root>
# To: root
# Subject: Cron <root@7a2c189f8bd0> doesnotexist
# Content-Type: text/plain; charset=ANSI_X3.4-1968
# Auto-Submitted: auto-generated
# Precedence: bulk
# X-Cron-Env: <SHELL=/bin/sh>
# X-Cron-Env: <HOME=/root>
# X-Cron-Env: <PATH=/usr/bin:/bin>
# X-Cron-Env: <LOGNAME=root>
# X-Cron-Env: <USER=root>
#
# output of running the cron command
###
# we want only the lines after the blank line

while true ; do
    while read line ; do
        if [ -z "$line" ] ; then
            # end of headers
            break
        fi
    done

    while read line ; do
        if [ -z "$line" ] ; then
            # eof
            break
        fi
        case "$line" in
            # beginning of next message
            "From: "*) break;;
        esac
        echo "$line"
    done
done
