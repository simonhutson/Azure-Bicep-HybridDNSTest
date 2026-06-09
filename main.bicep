targetScope = 'subscription'

@description('Azure region for all resource groups and resources.')
param location string = 'swedencentral'

@description('Resource group name for the simulated on-prem environment.')
param onPremResourceGroupName string = 'rg-onprem'

@description('Resource group name for the simulated Azure environment.')
param azureResourceGroupName string = 'rg-azure'

@description('Administrator username for the domain controller VM.')
param adminUsername string = 'azureadmin'

@description('Azure VM size used for the deployed Windows VMs.')
param vmSize string = 'Standard_D2ads_v5'

@secure()
@description('Administrator password for the domain controller VM.')
param adminPassword string

@secure()
@description('Directory Services Restore Mode password for the new Active Directory forest.')
param domainSafeModeAdminPassword string

@secure()
@description('Shared key used by both VNet-to-VNet IPsec VPN connections.')
param vpnSharedKey string

@description('Private DNS zone name for Azure VM registration.')
param privateDnsZoneName string = 'contoso.azure'

@description('Active Directory DNS domain name for the simulated on-prem forest.')
param activeDirectoryDomainName string = 'contoso.onprem'

@minLength(1)
@maxLength(15)
@description('Active Directory NetBIOS name for the simulated on-prem forest.')
param activeDirectoryNetbiosName string = 'CONTOSO'

@description('Tags applied to deployed resources.')
param tags object = {
  workload: 'hybrid-dns-test'
  environment: 'lab'
}

resource onPremResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: onPremResourceGroupName
  location: location
  tags: tags
}

resource azureResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: azureResourceGroupName
  location: location
  tags: tags
}

module onPrem './modules/onprem.bicep' = {
  name: 'onprem-environment'
  scope: onPremResourceGroup
  params: {
    location: location
    adminUsername: adminUsername
    vmSize: vmSize
    adminPassword: adminPassword
    domainSafeModeAdminPassword: domainSafeModeAdminPassword
    activeDirectoryDomainName: activeDirectoryDomainName
    activeDirectoryNetbiosName: activeDirectoryNetbiosName
    tags: tags
  }
}

module azure './modules/azure.bicep' = {
  name: 'azure-environment'
  scope: azureResourceGroup
  params: {
    location: location
    adminUsername: adminUsername
    vmSize: vmSize
    adminPassword: adminPassword
    privateDnsZoneName: privateDnsZoneName
    activeDirectoryDomainName: activeDirectoryDomainName
    onPremDnsServerIpAddress: onPrem.outputs.domainControllerPrivateIpAddress
    tags: tags
  }
}

module onPremToAzureConnection './modules/vpn-connection.bicep' = {
  name: 'onprem-to-azure-vpn-connection'
  scope: onPremResourceGroup
  params: {
    location: location
    connectionName: 'cn-vnet-onprem-to-vnet-azure'
    localVirtualNetworkGatewayResourceId: onPrem.outputs.virtualNetworkGatewayResourceId
    remoteVirtualNetworkGatewayResourceId: azure.outputs.virtualNetworkGatewayResourceId
    vpnSharedKey: vpnSharedKey
    tags: tags
  }
}

module azureToOnPremConnection './modules/vpn-connection.bicep' = {
  name: 'azure-to-onprem-vpn-connection'
  scope: azureResourceGroup
  params: {
    location: location
    connectionName: 'cn-vnet-azure-to-vnet-onprem'
    localVirtualNetworkGatewayResourceId: azure.outputs.virtualNetworkGatewayResourceId
    remoteVirtualNetworkGatewayResourceId: onPrem.outputs.virtualNetworkGatewayResourceId
    vpnSharedKey: vpnSharedKey
    tags: tags
  }
}

output onPremVirtualNetworkResourceId string = onPrem.outputs.virtualNetworkResourceId
output azureVirtualNetworkResourceId string = azure.outputs.virtualNetworkResourceId
output onPremRouteServerResourceId string = onPrem.outputs.routeServerResourceId
output azureRouteServerResourceId string = azure.outputs.routeServerResourceId
output privateDnsZoneResourceId string = azure.outputs.privateDnsZoneResourceId
output dnsResolverInboundEndpointPrivateIpAddress string = azure.outputs.dnsResolverInboundEndpointPrivateIpAddress
output domainControllerPrivateIpAddress string = onPrem.outputs.domainControllerPrivateIpAddress
