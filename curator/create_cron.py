#!/usr/bin/python

import sys
import json
import os

from crontab import CronTab

# we can't allow 'hours' since our index timestamp format doesn't allow for that level of granularity
#allowed_units = {'hours': 'hours', 'days': 'days', 'weeks': 'weeks', 'months': 'months'}
allowed_units = {'days': 'days', 'weeks': 'weeks', 'months': 'months'}

# allowed operations, currently we'll just allow delete?
allowed_operations = {'delete': 'delete'}

settings = sys.argv[1]

decoded = json.loads(settings)
#print 'decoded to:', decoded

connection_info = '--host ' + os.getenv('ES_HOST') + ' --port ' + os.getenv('ES_PORT') + ' --use_ssl --certificate ' + os.getenv('ES_CA') + ' --client-cert ' + os.getenv('ES_CLIENT_CERT') + ' --client-key ' + os.getenv('ES_CLIENT_KEY')
base_cmd = '/usr/bin/curator ' + connection_info + ' delete indices --timestring %Y.%m.%d'

curator_settings = {'hours': {}, 'days': {}, 'weeks':{}, 'months':{} };
default_command = base_cmd + ' --older-than 30 --time-unit days'

for project in decoded:
    for operation in decoded[project]:
        # eventually do something here with operation -- we'll check if it's a valid value and then use it as the operation instead of just 'delete'
        # integrate with allowed_operations
        # TODO: refactor logic to include operation in curator_settings

        for unit in decoded[project][operation]:
            value = int(decoded[project][operation][unit])

            if unit in allowed_units:
                default_command = default_command + " --exclude " + project + '.*'

                if unit.lower() == "days":
                    if value%7 == 0:
                        unit = "weeks"
                        value = value/7

                curator_settings[unit].setdefault(value, []).append(project)
            else:
                if unit.lower() == "hours":
                    print 'time unit "hours" is currently not supported due to our current index level granularity is in days'
                else:
                    print 'an unknown time unit of ' + unit + ' was provided... Record skipped'

my_cron  = CronTab()
default_job = my_cron.new(command=default_command, comment='Default generated job for curator')
default_job.every().day()

## {'weeks': {1: u'project6', 4: u'project5'}, 'months': {3: u'project4'}, 'days': {10: u'project3,project2'}}
for unit in curator_settings:
    for value in curator_settings[unit]:

        tab_command = base_cmd + ' --older-than ' + str(value) + ' --time-unit ' + unit

        for project in curator_settings[unit][value]:
            tab_command = tab_command + ' --index ' + project + '.*'

        job = my_cron.new(command=tab_command, comment='Generated job based on settings')
        job.every().day()

# run jobs before writing out to /etc/cron.d/curator
for job in my_cron:
    job.run()

my_cron.write('/etc/cron.d/curator')
