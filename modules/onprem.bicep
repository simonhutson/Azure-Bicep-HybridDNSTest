targetScope = 'resourceGroup'

@description('Azure region for resources.')
param location string = resourceGroup().location

@description('Administrator username for the domain controller VM.')
param adminUsername string

@description('Azure VM size used for the domain controller VM.')
param vmSize string = 'Standard_D2ads_v5'

@secure()
@description('Administrator password for the domain controller VM.')
param adminPassword string

@secure()
@description('Directory Services Restore Mode password for the new Active Directory forest.')
param domainSafeModeAdminPassword string

@description('Active Directory DNS domain name for the simulated on-prem forest.')
param activeDirectoryDomainName string = 'contoso.onprem'

@minLength(1)
@maxLength(15)
@description('Active Directory NetBIOS name for the simulated on-prem forest.')
param activeDirectoryNetbiosName string = 'CONTOSO'

@description('Tags applied to deployed resources.')
param tags object = {}

var virtualNetworkName = 'vnet-onprem'
var domainControllerName = 'vm-onprem01'
var domainControllerPrivateIpAddress = '10.0.5.4'
var adSubnetName = 'ad'
var bastionNetworkSecurityGroupName = 'nsg-onprem-bastion'
var addsConfigurationVersion = '2026-06-02.1'
var configureAddsCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& { $ErrorActionPreference = `"Stop`"; $domainName = `"${activeDirectoryDomainName}`"; $netbiosName = `"${activeDirectoryNetbiosName}`"; $safeModePassword = ConvertTo-SecureString `"${domainSafeModeAdminPassword}`" -AsPlainText -Force; if (Get-Service -Name NTDS -ErrorAction SilentlyContinue) { Write-Host `"Domain controller role already configured.`"; exit 0 }; Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools; Import-Module ADDSDeployment; Install-ADDSForest -DomainName $domainName -DomainNetbiosName $netbiosName -InstallDns -SafeModeAdministratorPassword $safeModePassword -Force -NoRebootOnCompletion; New-Item -Path C:/AzureData -ItemType Directory -Force | Out-Null; Set-Content -Path C:/AzureData/adds-promotion-requested.txt -Value (Get-Date -Format o); shutdown.exe /r /t 30 /c `"Completing AD DS forest promotion`"; exit 0 }"'

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

var subnetResourceIds = {
  ad: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, adSubnetName)
  routeServer: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, 'RouteServerSubnet')
}

module adNetworkSecurityGroup 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-ad'
  params: {
    name: 'nsg-ad'
    location: location
    enableTelemetry: false
    tags: tags
  }
}

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
      '10.0.0.0/8'
    ]
    dnsServers: [
      domainControllerPrivateIpAddress
    ]
    enableTelemetry: false
    subnets: [
      {
        name: adSubnetName
        addressPrefix: '10.0.5.0/24'
        networkSecurityGroupResourceId: adNetworkSecurityGroup.outputs.resourceId
      }
      {
        name: 'VirtualNetworkApplianceSubnet'
        addressPrefix: '10.0.4.0/24'
      }
      {
        name: 'RouteServerSubnet'
        addressPrefix: '10.0.3.0/24'
      }
      {
        name: 'AzureFirewallSubnet'
        addressPrefix: '10.0.2.0/24'
      }
      {
        name: 'AzureBastionSubnet'
        addressPrefix: '10.0.1.0/24'
        networkSecurityGroupResourceId: bastionNetworkSecurityGroup.outputs.resourceId
      }
      {
        name: 'GatewaySubnet'
        addressPrefix: '10.0.0.0/24'
      }
    ]
    tags: tags
  }
}

module bastionHost 'br/public:avm/res/network/bastion-host:0.8.2' = {
  name: 'bas-onprem-dev'
  params: {
    name: 'bas-onprem-dev'
    location: location
    skuName: 'Developer'
    virtualNetworkResourceId: virtualNetwork.outputs.resourceId
    enableTelemetry: false
    tags: tags
  }
}

resource routeServerPublicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-ars-onprem'
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
  name: 'ars-onprem'
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

module virtualNetworkGateway 'br/public:avm/res/network/virtual-network-gateway:0.11.1' = {
  name: 'vgw-onprem'
  params: {
    name: 'vgw-onprem'
    location: location
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    vpnGatewayGeneration: 'Generation1'
    skuName: 'VpnGw1AZ'
    primaryPublicIPName: 'vgw-onprem-zonal-pip1'
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

module domainController 'br/public:avm/res/compute/virtual-machine:0.22.1' = {
  name: domainControllerName
  params: {
    name: domainControllerName
    computerName: domainControllerName
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
        name: '${domainControllerName}-nic'
        nicSuffix: '-nic'
        deleteOption: 'Delete'
        enableAcceleratedNetworking: false
        dnsServers: [
          domainControllerPrivateIpAddress
        ]
        ipConfigurations: [
          {
            name: 'ipconfig1'
            subnetResourceId: subnetResourceIds.ad
            privateIPAddress: domainControllerPrivateIpAddress
            privateIPAllocationMethod: 'Static'
            pipConfiguration: null
          }
        ]
      }
    ]
    bootDiagnostics: true
    extensionAntiMalwareConfig: {
      enabled: true
    }
    extensionCustomScriptConfig: {
      name: 'configure-adds-dns'
      typeHandlerVersion: '1.10'
      forceUpdateTag: addsConfigurationVersion
      protectedSettings: {
        commandToExecute: configureAddsCommand
      }
    }
    enableTelemetry: false
    tags: tags
  }
  dependsOn: [
    virtualNetwork
  ]
}

output virtualNetworkResourceId string = virtualNetwork.outputs.resourceId
output virtualNetworkGatewayResourceId string = virtualNetworkGateway.outputs.resourceId
output routeServerResourceId string = routeServer.id
output domainControllerPrivateIpAddress string = domainControllerPrivateIpAddress
output adSubnetResourceId string = subnetResourceIds.ad
