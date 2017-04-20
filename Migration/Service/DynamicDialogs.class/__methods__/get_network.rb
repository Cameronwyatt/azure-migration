##########################
#
# Get the available networks that are attached to our account
#
##########################
require 'json'
require 'active_support/core_ext'
require 'azure-armrest'

@debug = false

def dump_root
  log(:info, 'Root:<$evm.root> Begin $evm.root.attributes')
  $evm.root.attributes.sort.each { |k, v| log(:info, "Root:<$evm.root> Attribute - #{k}: #{v}")}
  log(:info, 'Root:<$evm.root> End $evm.root.attributes')
  log(:info, '')
end

def log(level, message)
  $evm.log(level, message.to_s)
end

def get_configuration(tenant_id, client_id, client_key, subscription_id)
  params = {
      :tenant_id       => tenant_id,
      :client_id       => client_id,
      :client_key      => client_key,
      :subscription_id => subscription_id,
  }
  return Azure::Armrest::ArmrestService.configure(params)
end

begin
  dump_root if @debug

  # Azure Connection info is derived from info in VMDB
  provider        = $evm.vmdb(:ems).find_by_type("ManageIQ::Providers::Azure::CloudManager")
  client_id       = provider.authentication_userid
  client_key      = provider.authentication_password
  tenant_id       = provider.attributes['uid_ems']
  subscription_id = provider.subscription

  #Get basic connection to ARM REST Service
  config = get_configuration(tenant_id, client_id, client_key, subscription_id)

  vns = Azure::Armrest::Network::VirtualNetworkService.new(config)
  names = vns.list_all.map {|x| [x['name'],x['name']]}

  $evm.log(:info, "Network Names:|#{names}|")

  #dynamic dialog configuration
  dialog_field = $evm.object
  dialog_field['values']     = names.to_a
  dialog_field['sort_by']    = 'description'
  dialog_field['sort_order'] = 'ascending'
  dialog_field['data_type']  = 'string'
  dialog_field['required']   = 'false'

  log(:info, "Dynamic drop down values: #{dialog_field['values']}")

rescue => err
  log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")
end
