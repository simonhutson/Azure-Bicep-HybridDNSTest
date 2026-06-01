using 'main.bicep'

param location = 'swedencentral'
param onPremisesResourceGroupName = 'rg-on-premises'
param azureResourceGroupName = 'rg-azure'
param adminUsername = 'azureadmin'

// Replace these placeholders before deployment, or pass values at deployment time.
param adminPassword = 'R0seGr1een@1912'
param domainSafeModeAdminPassword = 'R0seGr1een@1912'
param vpnSharedKey = 'R0seGr1een@1912'

param privateDnsZoneName = 'viridor.local'
param tags = {
  workload: 'hybrid-dns-test'
  environment: 'lab'
}
using './main.bicep'

param location = 'uksouth'
param adminUsername = 'azureadmin'
param adminPassword = readEnvironmentVariable('ADMIN_PASSWORD')
param vpnSharedKey = readEnvironmentVariable('VPN_SHARED_KEY')
