targetScope = 'resourceGroup'

@description('Azure region for resources.')
param location string = resourceGroup().location

@description('Administrator username for the domain controller VM.')
param adminUsername string

@description('Azure VM size used for the domain controller VM.')
param vmSize string = 'Standard_D4ads_v5'

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
var addsConfigurationVersion = '2026-06-09.1'
var windowsServerGeneration2ImageReference = {
  publisher: 'MicrosoftWindowsServer'
  offer: 'WindowsServer'
  sku: '2025-datacenter-azure-edition'
  version: 'latest'
}
var configureAddsScript = format('''
$ErrorActionPreference = 'Stop'

function ConvertFrom-Utf8Base64 {{
  param([Parameter(Mandatory = $true)][string] $Value)
  [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value))
}}

$domainName = ConvertFrom-Utf8Base64 '{0}'
$netbiosName = ConvertFrom-Utf8Base64 '{1}'
$safeModePassword = ConvertTo-SecureString (ConvertFrom-Utf8Base64 '{2}') -AsPlainText -Force
$statePath = 'C:\AzureData'

New-Item -Path $statePath -ItemType Directory -Force | Out-Null

$networkProfiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
foreach ($networkProfile in $networkProfiles) {{
  if ($networkProfile.NetworkCategory -eq 'Public') {{
    Set-NetConnectionProfile -InterfaceIndex $networkProfile.InterfaceIndex -NetworkCategory Private
  }}
}}

if (-not (Get-NetFirewallRule -Name 'HybridDns-Allow-ICMPv4-In' -ErrorAction SilentlyContinue)) {{
  New-NetFirewallRule -Name 'HybridDns-Allow-ICMPv4-In' -DisplayName 'Hybrid DNS Lab - Allow ICMPv4 Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol ICMPv4 | Out-Null
}}
else {{
  Set-NetFirewallRule -Name 'HybridDns-Allow-ICMPv4-In' -Enabled True -Profile Any -Direction Inbound -Action Allow
}}

if (-not (Get-NetFirewallRule -Name 'HybridDns-Allow-ICMPv6-In' -ErrorAction SilentlyContinue)) {{
  New-NetFirewallRule -Name 'HybridDns-Allow-ICMPv6-In' -DisplayName 'Hybrid DNS Lab - Allow ICMPv6 Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol ICMPv6 | Out-Null
}}
else {{
  Set-NetFirewallRule -Name 'HybridDns-Allow-ICMPv6-In' -Enabled True -Profile Any -Direction Inbound -Action Allow
}}

$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
if (($computerSystem.DomainRole -ge 4) -and ($computerSystem.Domain -ieq $domainName)) {{
  Write-Host "Domain controller role is already configured for $domainName."
  exit 0
}}

$adDsFeature = Get-WindowsFeature -Name AD-Domain-Services
if (-not $adDsFeature.Installed) {{
  Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools
}}

Import-Module ADDSDeployment

$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
if ($computerSystem.DomainRole -lt 4) {{
  Install-ADDSForest -DomainName $domainName -DomainNetbiosName $netbiosName -InstallDns -SafeModeAdministratorPassword $safeModePassword -Force -NoRebootOnCompletion
  Set-Content -Path (Join-Path $statePath 'adds-promotion-requested.txt') -Value (Get-Date -Format o)
  shutdown.exe /r /t 30 /c 'Completing AD DS forest promotion'
}}
''', base64(activeDirectoryDomainName), base64(activeDirectoryNetbiosName), base64(domainSafeModeAdminPassword))
var configureAddsCommand = format('''
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$script = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('{0}')); Invoke-Expression $script"
''', base64(configureAddsScript))

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
      clusterMode: 'activeActiveNoBgp'
      secondPipName: 'vgw-onprem-zonal-pip2'
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
    securityType: 'TrustedLaunch'
    secureBootEnabled: true
    vTpmEnabled: true
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    imageReference: windowsServerGeneration2ImageReference
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
