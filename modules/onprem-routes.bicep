targetScope = 'resourceGroup'

@description('Azure region for resources.')
param location string = resourceGroup().location

@description('Private IP address of the Azure Firewall used as the next hop for on-prem routes to Azure subnets.')
param azureFirewallPrivateIpAddress string

@description('Azure subnet routes that should be reachable from the simulated on-prem subnet through Azure Firewall.')
param azureFirewallTransitRoutes array

@description('Tags applied to deployed resources.')
param tags object = {}

var virtualNetworkName = 'vnet-onprem'
var adSubnetName = 'ad'
var adSubnetAddressPrefix = '10.0.4.0/24'
var adNetworkSecurityGroupName = 'nsg-ad'

resource onPremToAzureFirewallRouteTable 'Microsoft.Network/routeTables@2023-11-01' = {
  name: 'rt-onprem-ad-to-azure-firewall'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [for route in azureFirewallTransitRoutes: {
      name: route.name
      properties: {
        addressPrefix: route.addressPrefix
        nextHopType: 'VirtualAppliance'
        nextHopIpAddress: azureFirewallPrivateIpAddress
      }
    }]
  }
  tags: tags
}

resource adSubnetRouteTableAssociation 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  name: '${virtualNetworkName}/${adSubnetName}'
  properties: {
    addressPrefix: adSubnetAddressPrefix
    networkSecurityGroup: {
      id: resourceId('Microsoft.Network/networkSecurityGroups', adNetworkSecurityGroupName)
    }
    routeTable: {
      id: onPremToAzureFirewallRouteTable.id
    }
  }
}

output routeTableResourceId string = onPremToAzureFirewallRouteTable.id
