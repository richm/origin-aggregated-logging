#!/bin/bash

# should we even have 'retention' level?  or just project : {unit : value} ?
#INDEX_MGMT='{"project1":{"delete":{"hours":"30"}},"project2":{"delete":{"days":"10"}},"project3":{"delete":{"days":"10"}},"project4":{"delete":{"months":"3"}},"project5":{"delete":{"weeks":"4"}},"project6":{"delete":{"hours":"168"}}}'

# this will parse out the retention settings, combine like settings, create cron line definitions for them with curator, run the jobs immediately, then run the jobs again every CURATOR_CRON_HOUR and CURATOR_CRON_MINUTE (by default, every midnight)
python -u run_cron.py "$INDEX_MGMT"
