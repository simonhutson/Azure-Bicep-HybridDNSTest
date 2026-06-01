using 'main.bicep'

param location = 'swedencentral'
param onPremisesResourceGroupName = 'rg-on-premises'
param azureResourceGroupName = 'rg-azure'
param adminUsername = 'azureadmin'
param adminPassword = readEnvironmentVariable('ADMIN_PASSWORD', '')
param domainSafeModeAdminPassword = readEnvironmentVariable('DOMAIN_SAFE_MODE_ADMIN_PASSWORD', '')
param vpnSharedKey = readEnvironmentVariable('VPN_SHARED_KEY', '')
param privateDnsZoneName = 'viridor.local'
param activeDirectoryDomainName = 'viridor.onprem'
param tags = {
  workload: 'hybrid-dns-test'
  environment: 'lab'
}
