using 'main.bicep'

param location = 'swedencentral'
param onPremResourceGroupName = 'rg-onprem'
param azureResourceGroupName = 'rg-azure'
param vmApplicationGalleryName = 'galHybridDns'
param ubuntuRouterVmApplicationVersion = '1.0.0'
param ubuntuRouterVmApplicationPackageUri = ''
param adminUsername = 'azureadmin'
param vmSize = 'Standard_D2ads_v5'
param adminPassword = readEnvironmentVariable('ADMIN_PASSWORD', '')
param domainSafeModeAdminPassword = readEnvironmentVariable('DOMAIN_SAFE_MODE_ADMIN_PASSWORD', '')
param vpnSharedKey = readEnvironmentVariable('VPN_SHARED_KEY', '')
param privateDnsZoneName = 'contoso.azure'
param activeDirectoryDomainName = 'contoso.onprem'
param activeDirectoryNetbiosName = 'CONTOSO'
param tags = {
  workload: 'hybrid-dns-test'
  environment: 'lab'
}
