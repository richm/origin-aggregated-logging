#!/bin/bash

set -euo pipefail

ES_VER=${ES_VER:-6.7.1}
ES_URL=${ES_URL:-https://github.com/elastic/elasticsearch/archive/v${ES_VER}.tar.gz}
OD_PARENT_VER=${OD_PARENT_VER:-0.9.0.0}
OD_PARENT_URL=${OD_PARENT_URL:-https://github.com/opendistro-for-elasticsearch/security-parent/archive/v${OD_PARENT_VER}.tar.gz}
OD_SEC_SSL_VER=${OD_SEC_SSL_VER:-${OD_PARENT_VER}}
OD_SEC_SSL_URL=${OD_SEC_SSL_URL:-https://github.com/opendistro-for-elasticsearch/security-ssl/archive/v${OD_SEC_SSL_VER}.tar.gz}
OD_SEC_VER=${OD_SEC_VER:-${OD_PARENT_VER}}
OD_SEC_URL=${OD_SEC_URL:-https://github.com/opendistro-for-elasticsearch/security/archive/v${OD_SEC_VER}.tar.gz}
OD_SEC_ADV_VER=${OD_SEC_ADV_VER:-${OD_PARENT_VER}}
OD_SEC_ADV_URL=${OD_SEC_ADV_URL:-https://github.com/opendistro-for-elasticsearch/security-advanced-modules/archive/v${OD_SEC_ADV_VER}.tar.gz}
VENDOR_BRANCH=${VENDOR_BRANCH:-es6-vendor}
cd $( dirname $0 )
cd ..
OALDIR=${OALDIR:-$( pwd )}
cd $OALDIR
curbranch=$( git rev-parse --abbrev-ref HEAD )
cat <<EOF
This script will grab the latest source release of the following components/versions:
Elasticsearch $ES_VER from $ES_URL
OpenDistro4ES parent $OD_PARENT_VER from $OD_PARENT_URL
OpenDistro4ES security-ssl $OD_SEC_SSL_VER from $OD_SEC_SSL_URL
OpenDistro4ES security $OD_SEC_VER from $OD_SEC_URL
OpenDistro4ES security-advanced-modules $OD_SEC_ADV_VER from $OD_SEC_ADV_URL
It will add or update the sources on the branch $VENDOR_BRANCH
You will need to use git status to add/modify/remove updated sources,
commit to the branch, then merge with $curbranch.
EOF

ESDIR=${ESDIR:-$OALDIR/elasticsearch}
VENDOR_DIR=${VENDOR_DIR:-$ESDIR/vendor}

pushd $OALDIR > /dev/null
if git branch $VENDOR_BRANCH > /dev/null 2>&1 ; then
    echo created new vendor branch $VENDOR_BRANCH
else
    echo using existing vendor branch $VENDOR_BRANCH
fi
if ! git checkout $VENDOR_BRANCH > /dev/null 2>&1 ; then
    echo ERROR: you have unsaved changes on $curbranch
    echo ERROR: cannot switch to vendor branch $VENDOR_BRANCH
    echo ERROR: please save your changes before using $0 again
    exit 1
fi
popd > /dev/null

manifest=$( mktemp )
tmptgz=$( mktemp )
trap "rm -f $manifest $tmptgz" EXIT

for pkg in elasticsearch security-parent security-ssl security security-advanced-modules ; do
    case $pkg in
    elasticsearch) url=$ES_URL; ver=$ES_VER ;;
    security-parent) url=$OD_PARENT_URL; ver=$OD_PARENT_VER ;;
    security-ssl) url=$OD_SEC_SSL_URL; ver=$OD_SEC_SSL_VER ;;
    security) url=$OD_SEC_URL; ver=$OD_SEC_VER ;;
    security-advanced-modules) url=$OD_SEC_ADV_URL; ver=$OD_SEC_ADV_VER ;;
    *) exit 1 ;;
    esac
    if ! curl -s -L -o $tmptgz $url ; then
        echo ERROR: unable to download $url
        exit 1
    fi
    if [ ! -d $VENDOR_DIR ] ; then
        mkdir -p $VENDOR_DIR
    fi
    if ! tar xfz $tmptgz -C $VENDOR_DIR ; then
        echo ERROR: unable to extract $url local file $tmptgz to $VENDOR_DIR/$pkg
        exit 1
    fi
    rm -rf $VENDOR_DIR/$pkg
    mv $VENDOR_DIR/$pkg-$ver $VENDOR_DIR/$pkg
    echo $pkg $ver $url >> $manifest
done

sort $manifest > $ESDIR/rh-manifest.txt

if git diff --exit-code ; then
    echo INFO: branch $VENDOR_BRANCH source is up-to-date
    git checkout $curbranch
else
    git commit -a -m "Vendor in latest Elasticsearch and components source"
    echo INFO: remember to push branch $VENDOR_BRANCH to origin
    git checkout $curbranch
    git merge $VENDOR_BRANCH
fi
