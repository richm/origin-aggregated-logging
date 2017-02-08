FROM registry.centos.org/sclo/ruby-23-centos7:latest

MAINTAINER OpenShift Development <dev@lists.openshift.redhat.com>

ENV HOME=/opt/app-root/src \
  PATH=/opt/app-root/src/bin:/opt/app-root/bin:$PATH \
  RUBY_VERSION=2.3 \
  FLUENTD_VERSION=0.14.12 \
  GEM_HOME=/opt/app-root/src

ARG SCL_VERSION=rh-ruby23

LABEL io.k8s.description="Fluentd container for collecting of docker container logs" \
  io.k8s.display-name="Fluentd ${FLUENTD_VERSION}" \
  io.openshift.expose-services="9200:http, 9300:http" \
  io.openshift.tags="logging,elk,fluentd"

# iproute needed for ip command to get ip addresses
USER 0
RUN rpmkeys --import file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7 && \
    yum install -y --setopt=tsflags=nodocs \
      iproute && \
    yum clean all
RUN mkdir -p ${HOME} && \
    scl enable ${SCL_VERSION} -- \
     gem install -N --conservative --minimal-deps \
      fluentd:${FLUENTD_VERSION} \
      fluent-plugin-kubernetes_metadata_filter \
      fluent-plugin-elasticsearch \
      fluent-plugin-systemd \
      systemd-journal \
      fluent-plugin-rewrite-tag-filter \
      fluent-plugin-secure-forward

ADD configs.d/ /etc/fluent/configs.d/
ADD run.sh generate_throttle_configs.rb ${HOME}/
ADD filter_common_data_model.rb /etc/fluent/plugin/

RUN mkdir -p /etc/fluent/configs.d/{dynamic,user} && \
    chmod 777 /etc/fluent/configs.d/dynamic && \
    ln -s /etc/fluent/configs.d/user/fluent.conf /etc/fluent/fluent.conf

WORKDIR ${HOME}
CMD ["sh", "run.sh"]
