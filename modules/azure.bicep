targetScope = 'resourceGroup'

@description('Azure region for resources.')
param location string = resourceGroup().location

@description('Administrator username for Azure test VMs.')
param adminUsername string

@secure()
@description('Administrator password for Azure test VMs.')
param adminPassword string

@description('Private DNS zone name.')
param privateDnsZoneName string = 'contoso.azure'

@description('Active Directory DNS domain name hosted by the simulated on-prem DNS server.')
param activeDirectoryDomainName string = 'contoso.onprem'

@description('Private IP address of the simulated on-prem DNS server.')
param onPremDnsServerIpAddress string

@description('Tags applied to deployed resources.')
param tags object = {}

var virtualNetworkName = 'vnet-azure'
var dnsResolverInboundEndpointPrivateIpAddress = '172.19.2.4'
var onPremDnsForwardingDomainName = endsWith(activeDirectoryDomainName, '.') ? activeDirectoryDomainName : '${activeDirectoryDomainName}.'

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
    addressPrefix: '172.19.1.0/25'
  }
  {
    name: 'GatewaySubnet'
    addressPrefix: '172.19.0.0/24'
  }
]

var subnetResourceIds = {
  dnsResolverInbound: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, 'dns-resolver-inbound')
  dnsResolverOutbound: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, 'dns-resolver-outbound')
  avd01: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, 'avd01')
  vcpeCorp: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, 'vcpe-corp')
}

var azureVmDefinitions = [
  {
    name: 'vm-azure01'
    subnetResourceId: subnetResourceIds.vcpeCorp
  }
  {
    name: 'vm-azure02'
    subnetResourceId: subnetResourceIds.avd01
  }
]

module networkSecurityGroups 'br/public:avm/res/network/network-security-group:0.5.3' = [for nsgName in nsgNames: {
  name: nsgName
  params: {
    name: nsgName
    location: location
    enableTelemetry: false
    tags: tags
  }
}]

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.9.0' = {
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

module bastionHost 'br/public:avm/res/network/bastion-host:0.8.2' = {
  name: 'bas-azure-dev'
  params: {
    name: 'bas-azure-dev'
    location: location
    skuName: 'Developer'
    virtualNetworkResourceId: virtualNetwork.outputs.resourceId
    enableTelemetry: false
    tags: tags
  }
}

resource azureFirewallPublicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-afw-azure-standard'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
  tags: tags
}

resource azureFirewall 'Microsoft.Network/azureFirewalls@2023-11-01' = {
  name: 'afw-azure-standard'
  location: location
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }
    threatIntelMode: 'Deny'
    ipConfigurations: [
      {
        name: 'pip-afw-azure-standard'
        properties: {
          subnet: {
            id: '${virtualNetwork.outputs.resourceId}/subnets/AzureFirewallSubnet'
          }
          publicIPAddress: {
            id: azureFirewallPublicIp.id
          }
        }
      }
    ]
  }
  tags: tags
}

resource dnsResolver 'Microsoft.Network/dnsResolvers@2025-05-01' = {
  name: 'dnspr-azure'
  location: location
  properties: {
    virtualNetwork: {
      id: virtualNetwork.outputs.resourceId
    }
  }
  tags: tags
}

resource dnsResolverInboundEndpoint 'Microsoft.Network/dnsResolvers/inboundEndpoints@2025-05-01' = {
  parent: dnsResolver
  name: 'inbound'
  location: location
  properties: {
    ipConfigurations: [
      {
        subnet: {
          id: subnetResourceIds.dnsResolverInbound
        }
        privateIpAddress: dnsResolverInboundEndpointPrivateIpAddress
        privateIpAllocationMethod: 'Static'
      }
    ]
  }
  tags: tags
}

resource dnsResolverOutboundEndpoint 'Microsoft.Network/dnsResolvers/outboundEndpoints@2025-05-01' = {
  parent: dnsResolver
  name: 'outbound'
  location: location
  properties: {
    subnet: {
      id: subnetResourceIds.dnsResolverOutbound
    }
  }
  tags: tags
}

resource dnsForwardingRuleset 'Microsoft.Network/dnsForwardingRulesets@2022-07-01' = {
  name: 'dnsfrs-azure-to-onprem'
  location: location
  properties: {
    dnsResolverOutboundEndpoints: [
      {
        id: dnsResolverOutboundEndpoint.id
      }
    ]
  }
  tags: tags
}

resource onPremDnsForwardingRule 'Microsoft.Network/dnsForwardingRulesets/forwardingRules@2022-07-01' = {
  parent: dnsForwardingRuleset
  name: 'rule-onprem-ad'
  properties: {
    domainName: onPremDnsForwardingDomainName
    forwardingRuleState: 'Enabled'
    targetDnsServers: [
      {
        ipAddress: onPremDnsServerIpAddress
        port: 53
      }
    ]
  }
}

resource dnsForwardingRulesetVirtualNetworkLink 'Microsoft.Network/dnsForwardingRulesets/virtualNetworkLinks@2022-07-01' = {
  parent: dnsForwardingRuleset
  name: 'link-vnet-azure'
  properties: {
    virtualNetwork: {
      id: virtualNetwork.outputs.resourceId
    }
  }
}

module privateDnsZone 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'pdns-${replace(privateDnsZoneName, '.', '-')}'
  params: {
    name: privateDnsZoneName
    enableTelemetry: false
    virtualNetworkLinks: [
      {
        name: 'link-vnet-azure-registration'
        virtualNetworkResourceId: virtualNetwork.outputs.resourceId
        registrationEnabled: true
      }
    ]
    tags: tags
  }
}

module azureVirtualMachines 'br/public:avm/res/compute/virtual-machine:0.22.1' = [for vm in azureVmDefinitions: {
  name: vm.name
  params: {
    name: vm.name
    computerName: vm.name
    location: location
    availabilityZone: -1
    osType: 'Windows'
    vmSize: 'Standard_D2ads_v5'
    adminUsername: adminUsername
    adminPassword: adminPassword
    imageReference: {
      publisher: 'MicrosoftWindowsServer'
      offer: 'WindowsServer'
      sku: '2025-datacenter-azure-edition'
      version: 'latest'
    }
    osDisk: {
      caching: 'ReadWrite'
      createOption: 'FromImage'
      deleteOption: 'Delete'
      managedDisk: {
        storageAccountType: 'StandardSSD_LRS'
      }
    }
    nicConfigurations: [
      {
        name: '${vm.name}-nic'
        nicSuffix: '-nic'
        deleteOption: 'Delete'
        enableAcceleratedNetworking: false
        ipConfigurations: [
          {
            name: 'ipconfig1'
            subnetResourceId: vm.subnetResourceId
            privateIPAllocationMethod: 'Dynamic'
            pipConfiguration: null
          }
        ]
      }
    ]
    bootDiagnostics: true
    extensionAntiMalwareConfig: {
      enabled: true
    }
    enableTelemetry: false
    tags: tags
  }
  dependsOn: [
    virtualNetwork
  ]
}]

module virtualNetworkGateway 'br/public:avm/res/network/virtual-network-gateway:0.11.1' = {
  name: 'vgw-azure'
  params: {
    name: 'vgw-azure'
    location: location
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    vpnGatewayGeneration: 'Generation1'
    skuName: 'VpnGw1AZ'
    primaryPublicIPName: 'vgw-azure-zonal-pip1'
    publicIpAvailabilityZones: [
      1
      2
      3
    ]
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
output azureFirewallPrivateIpAddress string = azureFirewall.properties.ipConfigurations[0].properties.privateIPAddress
output dnsResolverInboundEndpointPrivateIpAddress string = dnsResolverInboundEndpointPrivateIpAddress
