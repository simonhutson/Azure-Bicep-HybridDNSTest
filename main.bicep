targetScope = 'subscription'

@description('Azure region for all resource groups and resources.')
param location string = 'uksouth'

@description('Resource group name for the simulated on-premises environment.')
param onPremisesResourceGroupName string = 'rg-on-premises'

@description('Resource group name for the simulated Azure environment.')
param azureResourceGroupName string = 'rg-azure'

@description('Administrator username for the domain controller VM.')
param adminUsername string = 'azureadmin'

@secure()
@description('Administrator password for the domain controller VM.')
param adminPassword string

@secure()
@description('Directory Services Restore Mode password for the new Active Directory forest.')
param domainSafeModeAdminPassword string

@secure()
@description('Shared key used by both VNet-to-VNet IPsec VPN connections.')
param vpnSharedKey string

@description('Private DNS zone and Active Directory DNS domain name.')
param privateDnsZoneName string = 'viridor.local'

@description('Tags applied to deployed resources.')
param tags object = {
  workload: 'hybrid-dns-test'
  environment: 'lab'
}

resource onPremisesResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: onPremisesResourceGroupName
  location: location
  tags: tags
}

resource azureResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: azureResourceGroupName
  location: location
  tags: tags
}

module onPremises './modules/on-premises.bicep' = {
  name: 'on-premises-environment'
  scope: onPremisesResourceGroup
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    domainSafeModeAdminPassword: domainSafeModeAdminPassword
    privateDnsZoneName: privateDnsZoneName
    tags: tags
  }
}

module azure './modules/azure.bicep' = {
  name: 'azure-environment'
  scope: azureResourceGroup
  params: {
    location: location
    privateDnsZoneName: privateDnsZoneName
    onPremisesVirtualNetworkResourceId: onPremises.outputs.virtualNetworkResourceId
    onPremisesDomainControllerPrivateIpAddress: onPremises.outputs.domainControllerPrivateIpAddress
    tags: tags
  }
}

module onPremisesToAzureConnection './modules/vpn-connection.bicep' = {
  name: 'on-premises-to-azure-vpn-connection'
  scope: onPremisesResourceGroup
  params: {
    location: location
    connectionName: 'cn-vnet-on-premises-to-vnet-vwm01'
    localVirtualNetworkGatewayResourceId: onPremises.outputs.virtualNetworkGatewayResourceId
    remoteVirtualNetworkGatewayResourceId: azure.outputs.virtualNetworkGatewayResourceId
    vpnSharedKey: vpnSharedKey
    tags: tags
  }
}

module azureToOnPremisesConnection './modules/vpn-connection.bicep' = {
  name: 'azure-to-on-premises-vpn-connection'
  scope: azureResourceGroup
  params: {
    location: location
    connectionName: 'cn-vnet-vwm01-to-vnet-on-premises'
    localVirtualNetworkGatewayResourceId: azure.outputs.virtualNetworkGatewayResourceId
    remoteVirtualNetworkGatewayResourceId: onPremises.outputs.virtualNetworkGatewayResourceId
    vpnSharedKey: vpnSharedKey
    tags: tags
  }
}

output onPremisesVirtualNetworkResourceId string = onPremises.outputs.virtualNetworkResourceId
output azureVirtualNetworkResourceId string = azure.outputs.virtualNetworkResourceId
output privateDnsZoneResourceId string = azure.outputs.privateDnsZoneResourceId
output dnsResolverInboundEndpointPrivateIpAddress string = azure.outputs.dnsResolverInboundEndpointPrivateIpAddress
output domainControllerPrivateIpAddress string = onPremises.outputs.domainControllerPrivateIpAddress
