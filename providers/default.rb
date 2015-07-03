#
# Cookbook Name:: tomcat_bin
# Provider:: default
#
# Copyright 2014 Brian Clark
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

use_inline_resources if defined?(use_inline_resources)

def whyrun_supported?
  true
end

def service_name
  new_resource.service_name || ::File.basename(new_resource.home)
end

def http_connector
  return unless new_resource.http_port
  http = {
    'port' => new_resource.http_port,
    'protocol' => 'HTTP/1.1',
    'connectionTimeout' => '20000',
    'URIEncoding' => 'UTF-8'
  }
  http['executor'] = thread_pool['name'] if thread_pool
  http['redirectPort'] = new_resource.ssl_port if new_resource.ssl_port
  http.merge!(new_resource.http_additional || {})
end

def ssl_connector
  return unless new_resource.ssl_port
  ssl = {
    'port' => new_resource.ssl_port,
    'protocol' => 'HTTP/1.1',
    'connectionTimeout' => '20000',
    'URIEncoding' => 'UTF-8',
    'SSLEnabled' => 'true',
    'scheme' => 'https',
    'secure' => 'true',
    'sslProtocol' => 'TLS',
    'clientAuth' => 'false'
  }
  ssl['executor'] = thread_pool['name'] if thread_pool
  ssl.merge!(new_resource.ssl_additional || {})
end

def thread_pool
  return unless new_resource.pool_enabled
  {
    'name' => 'tomcatThreadPool',
    'namePrefix' => 'catalina-exec-'
  }.merge!(new_resource.pool_additional || {})
end

def ajp_connector
  return unless new_resource.ajp_port
  ajp = {
    'port' => new_resource.ajp_port,
    'protocol' => 'AJP/1.3',
    'URIEncoding' => 'UTF-8'
  }
  ajp['redirectPort'] = new_resource.ssl_port if new_resource.ssl_port
  ajp.merge!(new_resource.ajp_additional || {})
end

def access_log_valve
  return unless new_resource.access_log_enabled
  valve = {
    'className' => 'org.apache.catalina.valves.AccessLogValve',
    'prefix' => 'localhost_access_log',
    'suffix' => '.log',
    'rotatable' => 'false',
    'pattern' => 'common',
    'directory' => 'logs'
  }
  valve.merge!(new_resource.access_log_additional || {})
  valve
end

action :create do
  catalina_home = new_resource.home
  version = new_resource.version
  url = "#{node['tomcat_bin']['mirror']}/#{version}/tomcat-#{version}.tar.gz"
  tarball_name = ::File.basename(url)
  download_path = ::File.join(Chef::Config[:file_cache_path], tarball_name)

  if new_resource.log_dir
    unless ::Pathname.new(new_resource.log_dir).absolute?
      fail 'log_dir must be absolute if specified'
    end
    log_dir = new_resource.log_dir
  else
    log_dir = ::File.join(new_resource.home, 'logs')
  end

  group new_resource.group do
    system true
  end

  user new_resource.user do
    system true
    group new_resource.group
    shell '/bin/false'
  end

  remote_file download_path do
    source url
    owner 'root'
    group 'root'
    checksum node['tomcat_bin']['checksum']
  end

  directory catalina_home do
    owner 'root'
    group 'root'
    mode '0755'
    recursive true
  end

  bash 'extract tomcat' do
    user 'root'
    cwd Chef::Config[:file_cache_path]
    code <<-EOH
    tar xzf #{tarball_name} --strip-components 1 -C "#{catalina_home}"
    cd "#{catalina_home}"
    rm -rf logs temp work
    rm -rf bin/*.bat
    rm -rf webapps/ROOT webapps/docs webapps/examples
    chown root:#{new_resource.group} bin/* conf/* lib/* webapps/*
    chmod 0640 conf/* lib/* bin/*.jar
    chmod 0750 bin/*.sh webapps/*
    EOH
    not_if { ::File.directory?(::File.join(catalina_home, 'webapps')) }
  end

  %w(bin conf lib).each do |dir|
    directory ::File.join(catalina_home, dir) do
      owner 'root'
      group new_resource.group
      mode '0755'
    end
  end

  directory ::File.join(catalina_home, 'webapps') do
    owner 'root'
    group new_resource.group
    mode '0775'
  end

  %w(temp work).each do |dir|
    directory ::File.join(catalina_home, dir) do
      owner new_resource.user
      group new_resource.group
      mode '0755'
    end
  end

  directory log_dir do
    recursive true
    owner new_resource.user
    group new_resource.group
    mode '0755'
  end

  link "link_logs_#{new_resource.name}" do
    target_file ::File.join(new_resource.home, 'logs')
    to new_resource.log_dir
    not_if { new_resource.log_dir.nil? }
  end

  template "/etc/init.d/#{service_name}" do
    source 'tomcat.init.erb'
    variables(
      tomcat_home: new_resource.home,
      tomcat_user: new_resource.user,
      tomcat_name: service_name,
      kill_delay: new_resource.kill_delay
    )
    mode '0755'
    owner 'root'
    group 'root'
    cookbook new_resource.init_cookbook
    notifies :create, "ruby_block[restart_#{service_name}]", :immediately
  end

  template ::File.join(new_resource.home, 'bin', 'setenv.sh') do
    source 'setenv.sh.erb'
    mode '0750'
    owner 'root'
    group new_resource.group
    variables(config: new_resource)
    cookbook new_resource.setenv_cookbook
    notifies :create, "ruby_block[restart_#{service_name}]", :immediately
  end

  template ::File.join(new_resource.home, 'conf', 'server.xml') do
    source 'server.xml.erb'
    mode '0640'
    owner 'root'
    group new_resource.group
    variables(
      shutdown_port: new_resource.shutdown_port,
      thread_pool: thread_pool,
      http: http_connector,
      ssl: ssl_connector,
      ajp: ajp_connector,
      engine_valves: new_resource.engine_valves || {},
      host_valves: new_resource.host_valves || {},
      access_log_valve: access_log_valve
    )
    cookbook new_resource.server_xml_cookbook
    notifies :create, "ruby_block[restart_#{service_name}]", :immediately
  end

  template ::File.join(new_resource.home, 'conf', 'jmxremote.access') do
    source 'jmxremote.access.erb'
    mode '0600'
    owner new_resource.user
    group new_resource.group
    if new_resource.jmx_port.nil? || new_resource.jmx_authenticate == false
      action :delete
    else
      action :create
    end
    cookbook 'tomcat_bin'
    notifies :create, "ruby_block[restart_#{service_name}]", :immediately
  end

  template ::File.join(new_resource.home, 'conf', 'jmxremote.password') do
    source 'jmxremote.password.erb'
    mode '0600'
    owner new_resource.user
    group new_resource.group
    variables(
      control_password: new_resource.jmx_control_password,
      monitor_password: new_resource.jmx_monitor_password
    )
    if new_resource.jmx_port.nil? || new_resource.jmx_authenticate == false
      action :delete
    else
      action :create
    end
    cookbook 'tomcat_bin'
    notifies :create, "ruby_block[restart_#{service_name}]", :immediately
  end

  template ::File.join(new_resource.home, 'conf', 'logging.properties') do
    source 'logging.properties.erb'
    mode '0640'
    owner 'root'
    group new_resource.group
    cookbook new_resource.logging_properties_cookbook
    notifies :create, "ruby_block[restart_#{service_name}]", :immediately
  end

  logs = %w(catalina.out catalina.log manager.log
            host-manager.log localhost.log)
  log_paths = logs.map { |log| ::File.join(new_resource.home, 'logs', log) }
  if access_log_valve
    fname = access_log_valve['prefix'] + access_log_valve['suffix']
    log_paths << ::File.join(new_resource.home, 'logs', fname)
  end

  template "/etc/logrotate.d/#{service_name}" do
    source 'logrotate.erb'
    mode '0644'
    owner 'root'
    group 'root'
    variables(
      files: log_paths,
      frequency: new_resource.logrotate_frequency,
      rotate: new_resource.logrotate_count
    )
    cookbook new_resource.logrotate_cookbook
  end

  service service_name do # ~FC021 http://acrmp.github.io/foodcritic/#FC021
    supports restart: true, start: true, stop: true, status: true
    action new_resource.start_service ? [:enable, :start] : :nothing
    only_if { new_resource.start_service == true }
  end

  # Hack to prevent mulptiple starts/restarts on first-run
  ruby_block "restart_#{service_name}" do
    block do
      r = resources(service: service_name)
      a = Array.new(r.action)
      a << :restart unless a.include?(:restart)
      a.delete(:start) if a.include?(:restart)
      r.action(a)
    end
    action :nothing
    only_if { new_resource.start_service == true }
  end
end
