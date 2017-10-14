#
# Fluentd ViaQ data model Filter Plugin
#
# Copyright 2017 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
require 'time'
require 'date'

module ViaqDataModelFilterSystemd
  SYSTEMD_FIELD = 'systemd'.freeze
  SYSTEMD_K_FIELD = 'k'.freeze
  SYSTEMD_T_FIELD = 't'.freeze
  SYSTEMD_U_FIELD = 'u'.freeze
  K8S_FIELD = 'kubernetes'.freeze
  LOCALHOST = 'localhost'.freeze
  TIME_FIELD = 'time'.freeze
  AT_TIMESTAMP = '@timestamp'.freeze
  PID_FIELD = 'PID'.freeze
  SYSLOG_IDENTIFIER_FIELD = 'SYSLOG_IDENTIFIER'.freeze
  # MESSAGE_L is lower case 'message'
  MESSAGE_L = 'message'.freeze
  # MESSAGE_U is upper case 'MESSAGE'
  MESSAGE_U = 'MESSAGE'.freeze
  LEVEL = 'level'.freeze

  # map of journal fields to viaq data model field
  JOURNAL_FIELD_MAP_SYSTEMD_T = {
    '_AUDIT_LOGINUID'.freeze    => 'AUDIT_LOGINUID'.freeze,
    '_AUDIT_SESSION'.freeze     => 'AUDIT_SESSION'.freeze,
    '_BOOT_ID'.freeze           => 'BOOT_ID'.freeze,
    '_CAP_EFFECTIVE'.freeze     => 'CAP_EFFECTIVE'.freeze,
    '_CMDLINE'.freeze           => 'CMDLINE'.freeze,
    '_COMM'.freeze              => 'COMM'.freeze,
    '_EXE'.freeze               => 'EXE'.freeze,
    '_GID'.freeze               => 'GID'.freeze,
    '_MACHINE_ID'.freeze        => 'MACHINE_ID'.freeze,
    '_PID'.freeze               => 'PID'.freeze,
    '_SELINUX_CONTEXT'.freeze   => 'SELINUX_CONTEXT'.freeze,
    '_SYSTEMD_CGROUP'.freeze    => 'SYSTEMD_CGROUP'.freeze,
    '_SYSTEMD_OWNER_UID'.freeze => 'SYSTEMD_OWNER_UID'.freeze,
    '_SYSTEMD_SESSION'.freeze   => 'SYSTEMD_SESSION'.freeze,
    '_SYSTEMD_SLICE'.freeze     => 'SYSTEMD_SLICE'.freeze,
    '_SYSTEMD_UNIT'.freeze      => 'SYSTEMD_UNIT'.freeze,
    '_SYSTEMD_USER_UNIT'.freeze => 'SYSTEMD_USER_UNIT'.freeze,
    '_TRANSPORT'.freeze         => 'TRANSPORT'.freeze,
    '_UID'.freeze               => 'UID'.freeze
  }

  JOURNAL_FIELD_MAP_SYSTEMD_U = {
    'CODE_FILE'.freeze         => 'CODE_FILE'.freeze,
    'CODE_FUNCTION'.freeze     => 'CODE_FUNCTION'.freeze,
    'CODE_LINE'.freeze         => 'CODE_LINE'.freeze,
    'ERRNO'.freeze             => 'ERRNO'.freeze,
    'MESSAGE_ID'.freeze        => 'MESSAGE_ID'.freeze,
    'RESULT'.freeze            => 'RESULT'.freeze,
    'UNIT'.freeze              => 'UNIT'.freeze,
    'SYSLOG_FACILITY'.freeze   => 'SYSLOG_FACILITY'.freeze,
    'SYSLOG_IDENTIFIER'.freeze => 'SYSLOG_IDENTIFIER'.freeze,
    'SYSLOG_PID'.freeze        => 'SYSLOG_PID'.freeze
  }

  JOURNAL_FIELD_MAP_SYSTEMD_K = {
    '_KERNEL_DEVICE'.freeze    => 'KERNEL_DEVICE'.freeze,
    '_KERNEL_SUBSYSTEM'.freeze => 'KERNEL_SUBSYSTEM'.freeze,
    '_UDEV_SYSNAME'.freeze     => 'UDEV_SYSNAME'.freeze,
    '_UDEV_DEVNODE'.freeze     => 'UDEV_DEVNODE'.freeze,
    '_UDEV_DEVLINK'.freeze     => 'UDEV_DEVLINK'.freeze,
  }

  JOURNAL_TIME_FIELDS = ['_SOURCE_REALTIME_TIMESTAMP'.freeze, '__REALTIME_TIMESTAMP'.freeze]

  def process_journal_fields(tag, time, record, fmtr_type)
    systemd_t = {}
    JOURNAL_FIELD_MAP_SYSTEMD_T.each do |jkey, key|
      if record.key?(jkey)
        systemd_t[key] = record[jkey]
      end
    end
    systemd_u = {}
    JOURNAL_FIELD_MAP_SYSTEMD_U.each do |jkey, key|
      if record.key?(jkey)
        systemd_u[key] = record[jkey]
      end
    end
    systemd_k = {}
    JOURNAL_FIELD_MAP_SYSTEMD_K.each do |jkey, key|
      if record.key?(jkey)
        systemd_k[key] = record[jkey]
      end
    end
    unless systemd_t.empty?
      (record[SYSTEMD_FIELD] ||= {})[SYSTEMD_T_FIELD] = systemd_t
    end
    unless systemd_u.empty?
      (record[SYSTEMD_FIELD] ||= {})[SYSTEMD_U_FIELD] = systemd_u
    end
    unless systemd_k.empty?
      (record[SYSTEMD_FIELD] ||= {})[SYSTEMD_K_FIELD] = systemd_k
    end
    begin
      pri_index = ('%d'.freeze % record['PRIORITY'.freeze] || 9).to_i
      case
      when pri_index < 0
        pri_index = 9
      when pri_index > 9
        pri_index = 9
      end
    rescue
      pri_index = 9
    end
    record['level'.freeze] = ['emerg'.freeze, 'alert'.freeze, 'crit'.freeze, 'err'.freeze, 'warning'.freeze, 'notice'.freeze, 'info'.freeze, 'debug'.freeze, 'trace'.freeze, 'unknown'.freeze][pri_index]
    JOURNAL_TIME_FIELDS.each do |field|
      if (val = record[field])
        vali = val.to_i
        record[TIME_FIELD] = Time.at(vali / 1000000, vali % 1000000).utc.to_datetime.rfc3339(6)
        break
      end
    end
    case fmtr_type
    when :sys_journal
      record[MESSAGE_L] = record[MESSAGE_U]
      if record['_HOSTNAME'.freeze].eql?(LOCALHOST) && @docker_hostname
        record['hostname'.freeze] = @docker_hostname
      else
        record['hostname'.freeze] = record['_HOSTNAME'.freeze]
      end
    when :k8s_journal
      record[MESSAGE_L] = record[MESSAGE_L] || record[MESSAGE_U] || record['log'.freeze]
      if record.key?(K8S_FIELD) && record[K8S_FIELD].respond_to?(:fetch) && \
         (k8shost = record[K8S_FIELD].fetch('host'.freeze, nil))
        record['hostname'.freeze] = k8shost
      elsif @docker_hostname
        record['hostname'.freeze] = @docker_hostname
      else
        record['hostname'.freeze] = record['_HOSTNAME'.freeze]
      end
      transform_eventrouter(tag, record)
    end
  end
end
