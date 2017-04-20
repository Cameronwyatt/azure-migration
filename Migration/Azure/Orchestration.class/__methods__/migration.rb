##########################
#
# @author Jason Ritenour jritenour (at) redhat (dot) com
# @description This CloudForms automate method will migrate a VMware VM object (including disk) to Azure
# @updateHistory
#  * 04/20/2017 by Cameron Wyatt cameron.m.wyatt (at) gmail (dot) com - refactored into different methods and 
#    standardized naming conventions, logic, etc.
#
##########################
require 'active_support/core_ext'
require 'azure-armrest'
require 'json'
require 'net/scp'
require 'securerandom'
require 'winrm'

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

# Runs $ps_script on the specified $conversion_host using WinRM
def run_powershell_script(conversion_host, conversion_host_user, conversion_host_pw, ps_script)
  url_params = {
      :ipaddress => conversion_host,
      :port      => 5985
  }

  connect_params = {
      :user => conversion_host_user,
      :pass => conversion_host_pw
  }

  # Construct the URL to send to WinRM in order to invoke the powershell script with the disk conversion commands
  url   = "http://#{url_params[:ipaddress]}:#{url_params[:port]}/wsman"
  winrm = WinRM::WinRMWebService.new(url, :negotiate, connect_params)
  return winrm.run_powershell_script(ps_script)
end

# Uses the ARM REST gem to create IP Address configuration details
# Specify IPv4, the FQDN of what will be the new VM in Azure, etc.
def create_ip_object(config, location, vcenter_vm_name, resource_group, ipname)
  ips = Azure::Armrest::Network::IpAddressService.new(config)
  
  idle_timeout_in_minutes = 4

  ip_options = {
      :location => location,
      :properties => {
          :publicIPAddressVersion   => 'IPv4',
          :publicIPAllocationMethod => 'Dynamic',
          :idleTimeoutInMinutes     => idle_timeout_in_minutes,
          :dnsSettings              => {
                                         :domainNameLabel => vcenter_vm_name,
                                         :fqdn            => "#{vcenter_vm_name}.eastus2.cloudapp.azure.com"
                                       }
      }
  }

  ips.create(ipname, resource_group , ip_options)
  return ips
end

# Uses the ARM REST gem to create a network interface card object
# Pass it the name of the nic provided by the user $nicname and the $subnet
# Relies upon the IP Address object created in create_ip_object as the ID is needed
def create_nic_object(config, nicname, location, subnet, ip_id, resource_group)
  nis = Azure::Armrest::Network::NetworkInterfaceService.new(config)

  nic_options = {
      :name       => nicname,
      :location   => location,
      :properties => {
          :ipConfigurations => [
              {
                  :name => nicname,
                  :properties => {
                      :subnet          => {:id => subnet},
                      :publicIPAddress => {:id => ip_id.id}
                  }
              }
          ]
      }
  }

  nis.create(nicname, resource_group, nic_options)
  return nis.get(nicname, resource_group)
end

# Create the new VM in Azure
# Give the VM a name, stick it in a location, assign it a flavor ($size), set the 'clouduser' account to have the 
# $vmpass password specified by the user
# Attach storage that is a disk that was uploaded as a VHD. This is the VDDK disk that was originally attached to the
# VM that previously lived in vCenter and then converted
def create_vm(storage_account, vcenter_vm_name, location, size, vmpass, ostype, nic_object, resource_group)
  vms = Azure::Armrest::VirtualMachineService.new(config)

  src_uri = "https://#{storage_account}.blob.core.windows.net/upload/#{vcenter_vm_name}.vhd"
  vhd_uri = "http://#{storage_account}.blob.core.windows.net/upload/#{vcenter_vm_name}_#{SecureRandom.uuid}.vhd"
  
  vm_options =
      {
          :name => vcenter_vm_name,
          :location => location,
          :properties => {
              :hardwareProfile => { :vmSize => size },
              :osProfile => {
                  :adminUserName => 'clouduser',
                  :adminPassword => vmpass,
                  :computerName  => vcenter_vm_name
              },
              :storageProfile => {
                  :osDisk => {
                      :createOption => 'FromImage',
                      :caching      => 'ReadWrite',
                      :name         => "#{vcenter_vm_name}.vhd",
                      :osType       => ostype,
                      :image        => { :uri => src_uri }, # source
                      :vhd          => { :uri => vhd_uri }  # target
                  }
              },
              :networkProfile => {
                  :networkInterfaces => [{:id => nic_object.id}]
              }
          }
      }  
  return vms.create(vcenter_vm_name, resource_group, vm_options)
end

begin
  dump_root if @debug

  # The seal_vm Ansible playbook was run before this method in the state machine
  # The / ManageIQ / ConfigurationManagement / AnsibleTower / Operations / StateMachines / Job / wait_for_completion
  # method will wait for the job to complete in Tower before moving to the next method in the state machine.
  # If the playbook fails, wait_for_completion will set 'ae_result' to 'error' and the statemachine will halt
  # As such, we can safely assume at this point that the playbook has been run successfully
  
  vcenter_vm   = $evm.root['vm']
  vcenter_vm_name = vcenter_vm.name
  vcenter_vm_host = vcenter_vm.host

  # Shutdown system, as the azure deprovision process doesn't always do this
  unless vcenter_vm.power_state == 'off'
    vm_mig.stop
    log(:info, "Shutting down VM:|#{vcenter_vm_name}|")

    #Do a targetted refresh on just this VM (instead of the whole EMS)
    vcenter_vm.refresh

    #Now retry until the VM's power state is 'off'
    $evm.root['ae_result'] = 'retry'
    $evm.root['ae_retry_interval'] = '30.seconds'
  end

  # Dialog variables entered by the user
  attributes      = $evm.root.attributes
  storage_account = attributes['dialog_get_storage_account']
  resource_group  = attributes['dialog_get_resource_group']
  ipname          = attributes['dialog_ipname']
  subnet          = attributes['dialog_get_subnet']
  nicname         = attributes['dialog_nicname']
  vmpass          = attributes['dialog_vmpass']
  ostype          = attributes['dialog_ostype']
  size            = attributes['dialog_vmsize']

  # Provider variables
  vmware_provider =  vcenter_vm.ext_management_system.hostname
  vmware_user     =  vcenter_vm.ext_management_system.authentication_userid
  vmware_password =  vcenter_vm.ext_management_system.authentication_password

  # Schema variables
  conversion_host      = $evm.object['conversion_host']
  conversion_host_user = $evm.object['conversion_host_user']
  conversion_host_pw   = $evm.object.decrypt('conversion_host_pw')
  conversion_host_path = $evm.object['conversion_host_path']

  log(:info, "Preparing VM:|#{vcenter_vm_name}| for migration")

  # Craft the script the WinRM will execute on the vCenter Windows host
  # This script will run the necessary commands to convert the vCenter VDDK disk to VHD as required by Azure
  ps_script = <<PS_SCRIPT
$result = @{}

Import-Module 'C:\\Program Files\\Microsoft Virtual Machine Converter\\MvmcCmdlet.psd1'

$sourceUser= '#{vmware_user}'
$sourcePassword = ConvertTo-SecureString '#{vmware_password}' -AsPlainText -Force
$sourceCredential = New-Object PSCredential ($sourceUser, $sourcePassword)
$sourceConnection = New-MvmcSourceConnection -Server '#{vmware_provider}' -SourceCredential $sourceCredential -verbose

$sourceVM = Get-MvmcSourceVirtualMachine -SourceConnection $sourceConnection -verbose | where {$_.Name -match "#{vcenter_vm_name}" }

$destinationLiteralPath = '#{conversion_host_path}'
ConvertTo-MvmcVirtualHardDiskOvf -SourceConnection $sourceConnection -DestinationLiteralPath $destinationLiteralPath -GuestVmId $sourceVM.GuestVmId -vhdformat vhd
Select-AzureRmProfile -Path "C:\\creds\\azure.txt"
Add-AzureRmVhd -Destination 'https://#{storage_account}.blob.core.windows.net/upload/#{vcenter_vm_name}.vhd' -LocalFilePath "C:\\images\\#{vcenter_vm_name}\\disk-0.vhd" -ResourceGroupName #{resource_group}
$result

$result

PS_SCRIPT

  # Run the above powershell script on the conversion host using WinRM
  results = run_powershell_script(conversion_host, conversion_host_user, conversion_host_pw, ps_script)

  # Grab any errors that came back from WinRM
  # If there are errors, log them and then exit as we cannot proceed with the upload
  errors = results[:data].collect { |d| d[:stderr] }.join
  unless errors.blank?
    $evm.log(:error, "WinRM returned stderr:|#{errors}|")
    $evm.root['ae_result'] = 'error'
    exit MIQ_ABORT
  end

  # Grab the standard output of the command
  # Can do additional processing here
  data = results[:data].collect { |d| d[:stdout] }.join
  $evm.log(:info, "WinRM returned hash:|#{data}|")

  
  # Azure Connection info is derived from info in VMDB
  provider        = $evm.vmdb(:ems).find_by_type("ManageIQ::Providers::Azure::CloudManager")
  client_id       = provider.authentication_userid
  client_key      = provider.authentication_password
  tenant_id       = provider.attributes['uid_ems']
  subscription_id = provider.subscription
  location        = provider.attributes['provider_region']

  # Get basic connection to ARM REST Service
  config = get_configuration(tenant_id, client_id, client_key, subscription_id)

  # Create the IP Address object and get the ID
  ip_object = create_ip_object(config, location, vcenter_vm_name, resource_group, ipname)
  ip_id=ip_object.get(ipname, resource_group)

  # Create the NIC object using the $nicname and $subnet that the user specified
  # Also include the ID of the IP Address object created previously
  nic_object = create_nic_object(config, nicname, location, subnet, ip_id, resource_group)
  
  # Tie everything together by creating the VM object
  # This objection is a combination of the previous VMs disk that was converted from VDDK to VHD, the newly created NIC
  # object, and other parameters that the user has specified
  vm_object = create_vm(storage_account, vcenter_vm_name, location, size, vmpass, ostype, nic_object, resource_group)
  
  # We're done...do some diagnostic logging
  log(:info, "VM object has been created in Azure with name:|#{vcenter_vm_name}")
  log(:info, "VM details:|#{vm_object.inspect}|")

rescue => err
  log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")
end
