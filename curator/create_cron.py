#!/usr/bin/python

import sys
import json
import os

from crontab import CronTab

# we can't allow 'hours' since our index timestamp format doesn't allow for that level of granularity
#allowed_units = {'hours': 'hours', 'days': 'days', 'weeks': 'weeks', 'months': 'months'}
allowed_units = {'days': 'days', 'weeks': 'weeks', 'months': 'months'}

# allowed operations, currently we'll just allow delete
allowed_operations = {'delete': 'delete'}
curator_settings = {'delete': {}}

settings = sys.argv[1]

decoded = json.loads(settings)

connection_info = '--host ' + os.getenv('ES_HOST') + ' --port ' + os.getenv('ES_PORT') + ' --use_ssl --certificate ' + os.getenv('ES_CA') + ' --client-cert ' + os.getenv('ES_CLIENT_CERT') + ' --client-key ' + os.getenv('ES_CLIENT_KEY')

base_default_cmd = '/usr/bin/curator ' + connection_info + ' delete indices --timestring %Y.%m.%d'
default_command = base_default_cmd + ' --older-than ' + os.getenv('DEFAULT_DAYS') + ' --time-unit days'

for project in decoded:
    for operation in decoded[project]:
        if operation in allowed_operations:
            for unit in decoded[project][operation]:
                value = int(decoded[project][operation][unit])

                if unit in allowed_units:
                    default_command = default_command + " --exclude " + project + '.*'

                    if unit.lower() == "days":
                        if value%7 == 0:
                            unit = "weeks"
                            value = value/7

                    curator_settings[operation].setdefault(unit, {}).setdefault(value, []).append(project)
                else:
                    if unit.lower() == "hours":
                        print 'time unit "hours" is currently not supported due to our current index level granularity is in days'
                    else:
                        print 'an unknown time unit of ' + unit + ' was provided... Record skipped'
        else:
            print 'an unsupported or unknown operation ' + operation + ' was provided... Record skipped'

my_cron  = CronTab()
default_job = my_cron.new(command=default_command, comment='Default generated job for curator')
default_job.every().day()

## {'delete': {'weeks': {1: ['project1, project2], 3 : [project3]}, 'months': {1: [project 4]}}, 'archive': {'months': {'1', ['project1', 'project3']}} }
for operation in curator_settings:
    for unit in curator_settings[operation]:
        for value in curator_settings[operation][unit]:

            base_cmd = '/usr/bin/curator ' + connection_info + ' ' + operation + ' indices --timestring %Y.%m.%d'
            tab_command = base_cmd + ' --older-than ' + str(value) + ' --time-unit ' + unit

            for project in curator_settings[operation][unit][value]:
                tab_command = tab_command + ' --index ' + project + '.*'

            job = my_cron.new(command=tab_command, comment='Generated job based on settings')
            job.every().day()

# run jobs immediately
for job in my_cron:
    job.run()

while True:
    time.sleep(86400)
    for job in my_cron:
        job.run()
