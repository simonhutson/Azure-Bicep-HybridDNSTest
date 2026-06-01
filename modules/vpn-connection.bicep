targetScope = 'resourceGroup'

@description('Azure region for the connection resource.')
param location string = resourceGroup().location

@description('Name of the VPN connection.')
param connectionName string

@description('Resource ID of the local virtual network gateway.')
param localVirtualNetworkGatewayResourceId string

@description('Resource ID of the remote virtual network gateway.')
param remoteVirtualNetworkGatewayResourceId string

@secure()
@description('Shared key used by this IPsec VPN connection.')
param vpnSharedKey string

@description('Tags applied to deployed resources.')
param tags object = {}

module connection 'br/public:avm/res/network/connection:0.1.7' = {
  name: connectionName
  params: {
    name: connectionName
    location: location
    connectionType: 'Vnet2Vnet'
    virtualNetworkGateway1: {
      id: localVirtualNetworkGatewayResourceId
    }
    virtualNetworkGateway2ResourceId: remoteVirtualNetworkGatewayResourceId
    connectionProtocol: 'IKEv2'
    vpnSharedKey: vpnSharedKey
    enableTelemetry: false
    tags: tags
  }
}

output resourceId string = connection.outputs.resourceId
