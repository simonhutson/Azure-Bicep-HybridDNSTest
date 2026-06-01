targetScope = 'resourceGroup'

@description('Azure region for resources.')
param location string = resourceGroup().location

@description('Private DNS zone name.')
param privateDnsZoneName string = 'viridor.local'

@description('Resource ID of the simulated on-premises virtual network.')
param onPremisesVirtualNetworkResourceId string

@description('Static private IP address of ad01 in the simulated on-premises network.')
param onPremisesDomainControllerPrivateIpAddress string

@description('Tags applied to deployed resources.')
param tags object = {}

var virtualNetworkName = 'vnet-vwm01'

var nsgNames = [
  'nsg-zscaler-zpa'
  'nsg-avd01'
  'nsg-live'
  'nsg-dhcp'
  'nsg-unisim'
  'nsg-utilities'
  'nsg-vcpe-corp'
  'nsg-vcpe-iot'
  'nsg-vmb-management'
  'nsg-vcpe-sdwan'
  'nsg-fw04-corp'
  'nsg-fw04-iot'
  'nsg-fw04-untrust'
  'nsg-fw04-management'
]

var customSubnets = [
  {
    name: 'zscaler-zpa'
    addressPrefix: '172.19.60.0/28'
    nsgName: 'nsg-zscaler-zpa'
  }
  {
    name: 'avd01'
    addressPrefix: '172.19.40.0/24'
    nsgName: 'nsg-avd01'
  }
  {
    name: 'live'
    addressPrefix: '172.19.20.0/23'
    nsgName: 'nsg-live'
  }
  {
    name: 'dhcp'
    addressPrefix: '172.19.15.0/28'
    nsgName: 'nsg-dhcp'
  }
  {
    name: 'unisim'
    addressPrefix: '172.19.14.0/28'
    nsgName: 'nsg-unisim'
  }
  {
    name: 'utilities'
    addressPrefix: '172.19.10.0/23'
    nsgName: 'nsg-utilities'
  }
  {
    name: 'vcpe-corp'
    addressPrefix: '172.19.80.96/28'
    nsgName: 'nsg-vcpe-corp'
  }
  {
    name: 'vcpe-iot'
    addressPrefix: '172.19.80.112/28'
    nsgName: 'nsg-vcpe-iot'
  }
  {
    name: 'vmb-management'
    addressPrefix: '172.19.80.80/28'
    nsgName: 'nsg-vmb-management'
  }
  {
    name: 'vcpe-sdwan'
    addressPrefix: '172.19.80.64/28'
    nsgName: 'nsg-vcpe-sdwan'
  }
  {
    name: 'fw04-corp'
    addressPrefix: '172.19.85.96/28'
    nsgName: 'nsg-fw04-corp'
  }
  {
    name: 'fw04-iot'
    addressPrefix: '172.19.85.112/28'
    nsgName: 'nsg-fw04-iot'
  }
  {
    name: 'fw04-untrust'
    addressPrefix: '172.19.85.32/27'
    nsgName: 'nsg-fw04-untrust'
  }
  {
    name: 'fw04-management'
    addressPrefix: '172.19.85.80/28'
    nsgName: 'nsg-fw04-management'
  }
]

var customSubnetDefinitions = [for subnet in customSubnets: union({
  name: subnet.name
  addressPrefix: subnet.addressPrefix
}, empty(subnet.nsgName) ? {} : {
  networkSecurityGroupResourceId: resourceId('Microsoft.Network/networkSecurityGroups', subnet.nsgName)
})]

var platformSubnetDefinitions = [
  {
    name: 'dns-resolver-inbound'
    addressPrefix: '172.19.2.0/25'
    delegation: 'Microsoft.Network/dnsResolvers'
  }
  {
    name: 'dns-resolver-outbound'
    addressPrefix: '172.19.2.128/25'
    delegation: 'Microsoft.Network/dnsResolvers'
  }
  {
    name: 'AzureFirewallSubnet'
    addressPrefix: '172.19.1.0/26'
  }
  {
    name: 'AzureFirewallManagementSubnet'
    addressPrefix: '172.19.1.128/26'
  }
  {
    name: 'GatewaySubnet'
    addressPrefix: '172.19.0.0/27'
  }
]

var subnetResourceIds = {
  dnsResolverInbound: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, 'dns-resolver-inbound')
  dnsResolverOutbound: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, 'dns-resolver-outbound')
}

module networkSecurityGroups 'br/public:avm/res/network/network-security-group:0.5' = [for nsgName in nsgNames: {
  name: nsgName
  params: {
    name: nsgName
    location: location
    enableTelemetry: false
    tags: tags
  }
}]

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.9' = {
  name: virtualNetworkName
  params: {
    name: virtualNetworkName
    location: location
    addressPrefixes: [
      '172.19.0.0/16'
    ]
    subnets: concat(platformSubnetDefinitions, customSubnetDefinitions)
    enableTelemetry: false
    tags: tags
  }
  dependsOn: [
    networkSecurityGroups
  ]
}

module bastionHost 'br/public:avm/res/network/bastion-host:0.8' = {
  name: 'bas-vwm01-dev'
  params: {
    name: 'bas-vwm01-dev'
    location: location
    skuName: 'Developer'
    virtualNetworkResourceId: virtualNetwork.outputs.resourceId
    enableTelemetry: false
    tags: tags
  }
}

module azureFirewall 'br/public:avm/res/network/azure-firewall:0.10' = {
  name: 'afw-vwm01-basic'
  params: {
    name: 'afw-vwm01-basic'
    location: location
    virtualNetworkResourceId: virtualNetwork.outputs.resourceId
    azureSkuTier: 'Basic'
    availabilityZones: []
    enableManagementNic: true
    publicIPAddressObject: {
      name: 'pip-afw-vwm01-basic'
      availabilityZones: []
      skuName: 'Standard'
      skuTier: 'Regional'
    }
    managementIPAddressObject: {
      name: 'pip-afw-vwm01-basic-mgmt'
      availabilityZones: []
      skuName: 'Standard'
      skuTier: 'Regional'
    }
    enableTelemetry: false
    tags: tags
  }
}

module dnsResolver 'br/public:avm/res/network/dns-resolver:0.5' = {
  name: 'dnspr-vwm01'
  params: {
    name: 'dnspr-vwm01'
    location: location
    virtualNetworkResourceId: virtualNetwork.outputs.resourceId
    inboundEndpoints: [
      {
        name: 'inbound'
        subnetResourceId: subnetResourceIds.dnsResolverInbound
        privateIpAllocationMethod: 'Dynamic'
      }
    ]
    outboundEndpoints: [
      {
        name: 'outbound'
        subnetResourceId: subnetResourceIds.dnsResolverOutbound
      }
    ]
    enableTelemetry: false
    tags: tags
  }
}

module privateDnsZone 'br/public:avm/res/network/private-dns-zone:0.8' = {
  name: 'pdns-${replace(privateDnsZoneName, '.', '-')}'
  params: {
    name: privateDnsZoneName
    enableTelemetry: false
    a: [
      {
        name: 'ad01'
        ttl: 3600
        aRecords: [
          {
            ipv4Address: onPremisesDomainControllerPrivateIpAddress
          }
        ]
      }
    ]
    virtualNetworkLinks: [
      {
        name: 'link-vnet-vwm01-registration'
        virtualNetworkResourceId: virtualNetwork.outputs.resourceId
        registrationEnabled: true
      }
      {
        name: 'link-vnet-on-premises-resolution'
        virtualNetworkResourceId: onPremisesVirtualNetworkResourceId
        registrationEnabled: false
      }
    ]
    tags: tags
  }
}

module virtualNetworkGateway 'br/public:avm/res/network/virtual-network-gateway:0.11' = {
  name: 'vgw-vwm01'
  params: {
    name: 'vgw-vwm01'
    location: location
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    vpnGatewayGeneration: 'Generation1'
    skuName: 'VpnGw1AZ'
    publicIpAvailabilityZones: []
    clusterSettings: {
      clusterMode: 'activePassiveNoBgp'
    }
    virtualNetworkResourceId: virtualNetwork.outputs.resourceId
    enableTelemetry: false
    tags: tags
  }
}

output virtualNetworkResourceId string = virtualNetwork.outputs.resourceId
output virtualNetworkGatewayResourceId string = virtualNetworkGateway.outputs.resourceId
output privateDnsZoneResourceId string = privateDnsZone.outputs.resourceId
output azureFirewallPrivateIpAddress string = azureFirewall.outputs.privateIp
output dnsResolverInboundEndpointPrivateIpAddress string = dnsResolver.outputs.inboundEndpointsObject[0].properties.ipConfigurations[0].privateIpAddress
