targetScope = 'resourceGroup'

@description('Azure region for resources.')
param location string = resourceGroup().location

@description('Administrator username for Azure test VMs.')
param adminUsername string

@description('Azure VM size used for Azure test VMs.')
param vmSize string = 'Standard_D2ads_v5'

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
var bastionNetworkSecurityGroupName = 'nsg-azure-bastion'
var dnsResolverInboundEndpointPrivateIpAddress = '172.19.5.4'
var onPremVirtualNetworkAddressPrefix = '10.0.0.0/8'
var onPremDnsForwardingDomainName = endsWith(activeDirectoryDomainName, '.') ? activeDirectoryDomainName : '${activeDirectoryDomainName}.'

var bastionNetworkSecurityGroupRules = [
  {
    name: 'AllowHttpsInbound'
    properties: {
      priority: 100
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '443'
    }
  }
  {
    name: 'AllowGatewayManagerInbound'
    properties: {
      priority: 110
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'GatewayManager'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '443'
    }
  }
  {
    name: 'AllowBastionHostCommunication'
    properties: {
      priority: 120
      direction: 'Inbound'
      access: 'Allow'
      protocol: '*'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: [
        '8080'
        '5701'
      ]
    }
  }
  {
    name: 'AllowAzureLoadBalancerInbound'
    properties: {
      priority: 130
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'AzureLoadBalancer'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '443'
    }
  }
  {
    name: 'AllowSshRdpOutbound'
    properties: {
      priority: 140
      direction: 'Outbound'
      access: 'Allow'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: [
        '22'
        '3389'
      ]
    }
  }
  {
    name: 'AllowAzureCloudOutbound'
    properties: {
      priority: 150
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureCloud'
      destinationPortRange: '443'
    }
  }
  {
    name: 'AllowBastionCommunication'
    properties: {
      priority: 160
      direction: 'Outbound'
      access: 'Allow'
      protocol: '*'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: [
        '8080'
        '5701'
      ]
    }
  }
  {
    name: 'AllowHttpOutbound'
    properties: {
      priority: 170
      direction: 'Outbound'
      access: 'Allow'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'Internet'
      destinationPortRange: '80'
    }
  }
]

var firewallTransitAzureRoutes = [
  {
    name: 'to-zscaler-zpa'
    addressPrefix: '172.19.60.0/28'
  }
  {
    name: 'to-avd01'
    addressPrefix: '172.19.40.0/24'
  }
  {
    name: 'to-live'
    addressPrefix: '172.19.20.0/23'
  }
  {
    name: 'to-dhcp'
    addressPrefix: '172.19.15.0/28'
  }
  {
    name: 'to-unisim'
    addressPrefix: '172.19.14.0/28'
  }
  {
    name: 'to-utilities'
    addressPrefix: '172.19.10.0/23'
  }
  {
    name: 'to-vcpe-corp'
    addressPrefix: '172.19.80.96/28'
  }
  {
    name: 'to-vcpe-iot'
    addressPrefix: '172.19.80.112/28'
  }
]

var firewallTransitAzureAddressPrefixes = [for route in firewallTransitAzureRoutes: route.addressPrefix]

var azureFirewallRouteTableDefinitions = [
  {
    name: 'rt-zscaler-zpa'
    subnetName: 'zscaler-zpa'
    subnetAddressPrefix: '172.19.60.0/28'
    networkSecurityGroupName: 'nsg-zscaler-zpa'
    routes: [
      {
        name: 'to-onprem'
        addressPrefix: onPremVirtualNetworkAddressPrefix
      }
      firewallTransitAzureRoutes[1]
      firewallTransitAzureRoutes[2]
      firewallTransitAzureRoutes[3]
      firewallTransitAzureRoutes[4]
      firewallTransitAzureRoutes[5]
      firewallTransitAzureRoutes[6]
      firewallTransitAzureRoutes[7]
    ]
  }
  {
    name: 'rt-avd01'
    subnetName: 'avd01'
    subnetAddressPrefix: '172.19.40.0/24'
    networkSecurityGroupName: 'nsg-avd01'
    routes: [
      {
        name: 'to-onprem'
        addressPrefix: onPremVirtualNetworkAddressPrefix
      }
      firewallTransitAzureRoutes[0]
      firewallTransitAzureRoutes[2]
      firewallTransitAzureRoutes[3]
      firewallTransitAzureRoutes[4]
      firewallTransitAzureRoutes[5]
      firewallTransitAzureRoutes[6]
      firewallTransitAzureRoutes[7]
    ]
  }
  {
    name: 'rt-live'
    subnetName: 'live'
    subnetAddressPrefix: '172.19.20.0/23'
    networkSecurityGroupName: 'nsg-live'
    routes: [
      {
        name: 'to-onprem'
        addressPrefix: onPremVirtualNetworkAddressPrefix
      }
      firewallTransitAzureRoutes[0]
      firewallTransitAzureRoutes[1]
      firewallTransitAzureRoutes[3]
      firewallTransitAzureRoutes[4]
      firewallTransitAzureRoutes[5]
      firewallTransitAzureRoutes[6]
      firewallTransitAzureRoutes[7]
    ]
  }
  {
    name: 'rt-dhcp'
    subnetName: 'dhcp'
    subnetAddressPrefix: '172.19.15.0/28'
    networkSecurityGroupName: 'nsg-dhcp'
    routes: [
      {
        name: 'to-onprem'
        addressPrefix: onPremVirtualNetworkAddressPrefix
      }
      firewallTransitAzureRoutes[0]
      firewallTransitAzureRoutes[1]
      firewallTransitAzureRoutes[2]
      firewallTransitAzureRoutes[4]
      firewallTransitAzureRoutes[5]
      firewallTransitAzureRoutes[6]
      firewallTransitAzureRoutes[7]
    ]
  }
  {
    name: 'rt-unisim'
    subnetName: 'unisim'
    subnetAddressPrefix: '172.19.14.0/28'
    networkSecurityGroupName: 'nsg-unisim'
    routes: [
      {
        name: 'to-onprem'
        addressPrefix: onPremVirtualNetworkAddressPrefix
      }
      firewallTransitAzureRoutes[0]
      firewallTransitAzureRoutes[1]
      firewallTransitAzureRoutes[2]
      firewallTransitAzureRoutes[3]
      firewallTransitAzureRoutes[5]
      firewallTransitAzureRoutes[6]
      firewallTransitAzureRoutes[7]
    ]
  }
  {
    name: 'rt-utilities'
    subnetName: 'utilities'
    subnetAddressPrefix: '172.19.10.0/23'
    networkSecurityGroupName: 'nsg-utilities'
    routes: [
      {
        name: 'to-onprem'
        addressPrefix: onPremVirtualNetworkAddressPrefix
      }
      firewallTransitAzureRoutes[0]
      firewallTransitAzureRoutes[1]
      firewallTransitAzureRoutes[2]
      firewallTransitAzureRoutes[3]
      firewallTransitAzureRoutes[4]
      firewallTransitAzureRoutes[6]
      firewallTransitAzureRoutes[7]
    ]
  }
  {
    name: 'rt-vcpe-corp'
    subnetName: 'vcpe-corp'
    subnetAddressPrefix: '172.19.80.96/28'
    networkSecurityGroupName: 'nsg-vcpe-corp'
    routes: [
      {
        name: 'to-onprem'
        addressPrefix: onPremVirtualNetworkAddressPrefix
      }
      firewallTransitAzureRoutes[0]
      firewallTransitAzureRoutes[1]
      firewallTransitAzureRoutes[2]
      firewallTransitAzureRoutes[3]
      firewallTransitAzureRoutes[4]
      firewallTransitAzureRoutes[5]
      firewallTransitAzureRoutes[7]
    ]
  }
  {
    name: 'rt-vcpe-iot'
    subnetName: 'vcpe-iot'
    subnetAddressPrefix: '172.19.80.112/28'
    networkSecurityGroupName: 'nsg-vcpe-iot'
    routes: [
      {
        name: 'to-onprem'
        addressPrefix: onPremVirtualNetworkAddressPrefix
      }
      firewallTransitAzureRoutes[0]
      firewallTransitAzureRoutes[1]
      firewallTransitAzureRoutes[2]
      firewallTransitAzureRoutes[3]
      firewallTransitAzureRoutes[4]
      firewallTransitAzureRoutes[5]
      firewallTransitAzureRoutes[6]
    ]
  }
]

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
    addressPrefix: '172.19.5.0/25'
    delegation: 'Microsoft.Network/dnsResolvers'
  }
  {
    name: 'dns-resolver-outbound'
    addressPrefix: '172.19.5.128/25'
    delegation: 'Microsoft.Network/dnsResolvers'
  }
  {
    name: 'VirtualNetworkApplianceSubnet'
    addressPrefix: '172.19.4.0/24'
  }
  {
    name: 'RouteServerSubnet'
    addressPrefix: '172.19.3.0/24'
  }
  {
    name: 'AzureFirewallSubnet'
    addressPrefix: '172.19.2.0/24'
  }
  {
    name: 'AzureBastionSubnet'
    addressPrefix: '172.19.1.0/24'
    networkSecurityGroupResourceId: resourceId('Microsoft.Network/networkSecurityGroups', bastionNetworkSecurityGroupName)
  }
  {
    name: 'GatewaySubnet'
    addressPrefix: '172.19.0.0/24'
  }
]

var subnetResourceIds = {
  dnsResolverInbound: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, 'dns-resolver-inbound')
  dnsResolverOutbound: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, 'dns-resolver-outbound')
  routeServer: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, 'RouteServerSubnet')
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

module bastionNetworkSecurityGroup 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: bastionNetworkSecurityGroupName
  params: {
    name: bastionNetworkSecurityGroupName
    location: location
    securityRules: bastionNetworkSecurityGroupRules
    enableTelemetry: false
    tags: tags
  }
}

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
    bastionNetworkSecurityGroup
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

resource routeServerPublicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-ars-azure'
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

resource routeServer 'Microsoft.Network/virtualHubs@2023-11-01' = {
  name: 'ars-azure'
  location: location
  properties: {
    sku: 'Standard'
  }
  tags: tags
}

resource routeServerIpConfiguration 'Microsoft.Network/virtualHubs/ipConfigurations@2023-11-01' = {
  parent: routeServer
  name: 'ipconfig1'
  properties: {
    subnet: {
      id: subnetResourceIds.routeServer
    }
    publicIPAddress: {
      id: routeServerPublicIp.id
    }
  }
  dependsOn: [
    virtualNetwork
  ]
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

resource azureFirewallPolicy 'Microsoft.Network/firewallPolicies@2023-11-01' = {
  name: 'afwp-azure-standard'
  location: location
  properties: {
    threatIntelMode: 'Deny'
  }
  tags: tags
}

resource azureFirewallPolicyRuleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-11-01' = {
  parent: azureFirewallPolicy
  name: 'DefaultNetworkRuleCollectionGroup'
  properties: {
    priority: 100
    ruleCollections: [
      {
        name: 'AllowHybridSubnetTraffic'
        priority: 100
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            name: 'AllowRequestedAzureSubnets'
            ruleType: 'NetworkRule'
            ipProtocols: [
              'Any'
            ]
            sourceAddresses: firewallTransitAzureAddressPrefixes
            destinationAddresses: firewallTransitAzureAddressPrefixes
            destinationPorts: [
              '*'
            ]
          }
          {
            name: 'AllowAzureSubnetsToOnPrem'
            ruleType: 'NetworkRule'
            ipProtocols: [
              'Any'
            ]
            sourceAddresses: firewallTransitAzureAddressPrefixes
            destinationAddresses: [
              onPremVirtualNetworkAddressPrefix
            ]
            destinationPorts: [
              '*'
            ]
          }
          {
            name: 'AllowOnPremToAzureSubnets'
            ruleType: 'NetworkRule'
            ipProtocols: [
              'Any'
            ]
            sourceAddresses: [
              onPremVirtualNetworkAddressPrefix
            ]
            destinationAddresses: firewallTransitAzureAddressPrefixes
            destinationPorts: [
              '*'
            ]
          }
        ]
      }
    ]
  }
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
    firewallPolicy: {
      id: azureFirewallPolicy.id
    }
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

resource azureFirewallRouteTables 'Microsoft.Network/routeTables@2023-11-01' = [for routeTable in azureFirewallRouteTableDefinitions: {
  name: routeTable.name
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [for route in routeTable.routes: {
      name: route.name
      properties: {
        addressPrefix: route.addressPrefix
        nextHopType: 'VirtualAppliance'
        nextHopIpAddress: azureFirewall.properties.ipConfigurations[0].properties.privateIPAddress
      }
    }]
  }
  tags: tags
}]

resource gatewaySubnetFirewallTransitRouteTable 'Microsoft.Network/routeTables@2023-11-01' = {
  name: 'rt-gateway-to-firewall-transit'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [for route in firewallTransitAzureRoutes: {
      name: route.name
      properties: {
        addressPrefix: route.addressPrefix
        nextHopType: 'VirtualAppliance'
        nextHopIpAddress: azureFirewall.properties.ipConfigurations[0].properties.privateIPAddress
      }
    }]
  }
  tags: tags
}

@batchSize(1)
resource azureFirewallRouteTableSubnetAssociations 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = [for (routeTable, routeTableIndex) in azureFirewallRouteTableDefinitions: {
  name: '${virtualNetworkName}/${routeTable.subnetName}'
  properties: {
    addressPrefix: routeTable.subnetAddressPrefix
    networkSecurityGroup: {
      id: resourceId('Microsoft.Network/networkSecurityGroups', routeTable.networkSecurityGroupName)
    }
    routeTable: {
      id: azureFirewallRouteTables[routeTableIndex].id
    }
  }
}]

resource gatewaySubnetFirewallTransitRouteTableAssociation 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  name: '${virtualNetworkName}/GatewaySubnet'
  properties: {
    addressPrefix: '172.19.0.0/24'
    routeTable: {
      id: gatewaySubnetFirewallTransitRouteTable.id
    }
  }
  dependsOn: [
    azureFirewallRouteTableSubnetAssociations
  ]
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
    licenseType: 'Windows_Server'
    vmSize: vmSize
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
  dependsOn: [
    gatewaySubnetFirewallTransitRouteTableAssociation
  ]
}

output virtualNetworkResourceId string = virtualNetwork.outputs.resourceId
output virtualNetworkGatewayResourceId string = virtualNetworkGateway.outputs.resourceId
output routeServerResourceId string = routeServer.id
output privateDnsZoneResourceId string = privateDnsZone.outputs.resourceId
output azureFirewallPrivateIpAddress string = azureFirewall.properties.ipConfigurations[0].properties.privateIPAddress
output firewallTransitAzureRoutes array = firewallTransitAzureRoutes
output dnsResolverInboundEndpointPrivateIpAddress string = dnsResolverInboundEndpointPrivateIpAddress
