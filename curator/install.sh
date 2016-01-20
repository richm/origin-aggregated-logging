#!/bin/bash

set -ex

rpm -q epel-release || yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
yum install -y --setopt=tsflags=nodocs \
  python-pip \
  cronie
pip install elasticsearch-curator
yum clean all

# HACK HACK HACK - remove when fixed upstream
yum install -y --setopt=tsflags=nodocs \
    git
git clone -b issue-344 https://github.com/richm/elasticsearch-py.git
pushd elasticsearch-py
python setup.py install
popd
git clone -b issue-520 https://github.com/richm/curator.git
pushd curator
python setup.py install
popd
yum clean all
# HACK HACK HACK - remove when fixed upstream

mkdir -p ${HOME}

if [ -z "$CURATOR_CA" ] ; then
    export CURATOR_CA=/etc/curator/keys/ca
fi
if [ -z "$CURATOR_CLIENT_CERT" ] ; then
    export CURATOR_CLIENT_CERT=/etc/curator/keys/cert
fi
if [ -z "$CURATOR_CLIENT_KEY" ] ; then
    export CURATOR_CLIENT_KEY=/etc/curator/keys/key
fi

# get the current crontab
cf=`mktemp`
crontab -u 0 -l > $cf 2> /dev/null || echo ignore empty crontab
# add our crontab
cat >> $cf <<EOF
$CURATOR_CRON_MINUTE $CURATOR_CRON_HOUR * * * /usr/bin/curator --host $ES_HOST --port $ES_PORT --use_ssl --certificate $CURATOR_CA --client-cert $CURATOR_CLIENT_CERT --client-key $CURATOR_CLIENT_KEY delete indices --time-unit $CURATOR_TIME_UNIT --older-than $CURATOR_DELETE_OLDER
EOF
# tell cron to use it
crontab -u 0 $cf
rm -f $cf
crontab -u 0 -l
