FROM centos:centos7

MAINTAINER OpenShift Development <dev@lists.openshift.redhat.com>

ENV HOME=/opt/app-root/src \
  PATH=/opt/app-root/src/bin:/opt/app-root/bin:$PATH \
  RUBY_VERSION=2.0 \
  FLUENTD_VERSION=0.12.23 \
  GEM_HOME=/opt/app-root/src \
  THROTTLE_CONF_LOCATION=/etc/throttle-settings

LABEL io.k8s.description="Fluentd container for collecting of docker container logs" \
  io.k8s.display-name="Fluentd ${FLUENTD_VERSION}" \
  io.openshift.expose-services="9200:http, 9300:http" \
  io.openshift.tags="logging,elk,fluentd"

RUN rpmkeys --import file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7 && \
  yum install -y --setopt=tsflags=nodocs \
  git \
  gcc-c++ \
  ruby \
  ruby-devel \
  libcurl-devel \
  make rubygem-rake rubygem-bundler which libicu-devel zlib-devel && \
  mkdir -p ${HOME} && \
  git clone https://github.com/richm/fluent-plugin-kubernetes_metadata_filter -b journald-containerhash && \
  gem install --no-rdoc --no-ri fluentd:${FLUENTD_VERSION} fluent-plugin-elasticsearch fluent-plugin-flatten-hash fluent-plugin-systemd systemd-journal fluent-plugin-rewrite-tag-filter && \
  pushd fluent-plugin-kubernetes_metadata_filter && GEM_HOME=vendor bundle install && GEM_HOME=vendor rake build && popd && \
  ls -alrtF --color=auto /fluent-plugin-kubernetes_metadata_filter && \
  gem install --no-rdoc --no-ri /fluent-plugin-kubernetes_metadata_filter/pkg/fluent-plugin-kubernetes_metadata_filter-0.21.0.gem && \
  mkdir -p ${THROTTLE_CONF_LOCATION} && \
  touch ${THROTTLE_CONF_LOCATION}/settings

ADD fluent.conf /etc/fluent/fluent.conf
ADD configs.d/ /etc/fluent/configs.d/
ADD run.sh generate_throttle_configs.rb \
    fluentd_es_copy_config.conf fluentd_es_ops_copy_config.conf \
    ${HOME}/
ADD out_elasticsearch_dynamic.rb ${HOME}/gems/fluent-plugin-elasticsearch-1.5.0/lib/fluent/plugin/out_elasticsearch_dynamic.rb

WORKDIR ${HOME}

CMD ["sh", "run.sh"]
