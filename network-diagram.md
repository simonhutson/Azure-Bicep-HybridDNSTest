# Network Diagram

This diagram reflects the lab topology defined by [main.bicep](main.bicep), [modules/onprem.bicep](modules/onprem.bicep), and [modules/azure.bicep](modules/azure.bicep).

```mermaid
flowchart LR
  Internet((Internet))

  subgraph OnPremRG["rg-onprem"]
    subgraph OnPremVNet["vnet-onprem<br/>10.0.0.0/8"]
      subgraph OnPremGatewaySubnet["GatewaySubnet<br/>10.0.0.0/24"]
        OnPremVgw["vgw-onprem<br/>VpnGw1AZ<br/>active-active"]
      end

      subgraph OnPremBastionSubnet["AzureBastionSubnet<br/>10.0.1.0/24"]
        OnPremBastion["bas-onprem-dev"]
      end

      OnPremFirewallSubnet["AzureFirewallSubnet<br/>10.0.2.0/24"]

      subgraph OnPremRouteServerSubnet["RouteServerSubnet<br/>10.0.3.0/24"]
        OnPremRouteServer["ars-onprem"]
      end

      OnPremNvaSubnet["VirtualNetworkApplianceSubnet<br/>10.0.4.0/24"]

      subgraph OnPremAdSubnet["ad<br/>10.0.5.0/24"]
        OnPremDc["vm-onprem01<br/>10.0.5.4<br/>AD DS + DNS"]
      end
    end
  end

  subgraph AzureRG["rg-azure"]
    subgraph AzureVNet["vnet-azure<br/>172.19.0.0/16"]
      subgraph AzureGatewaySubnet["GatewaySubnet<br/>172.19.0.0/24"]
        AzureVgw["vgw-azure<br/>VpnGw1AZ<br/>active-active"]
        GatewayRouteTable["rt-gateway-to-firewall-transit"]
      end

      subgraph AzureBastionSubnet["AzureBastionSubnet<br/>172.19.1.0/24"]
        AzureBastion["bas-azure-dev"]
      end

      subgraph AzureFirewallSubnet["AzureFirewallSubnet<br/>172.19.2.0/24"]
        AzureFirewall["afw-azure-standard<br/>Azure Firewall Standard"]
      end

      subgraph AzureRouteServerSubnet["RouteServerSubnet<br/>172.19.3.0/24"]
        AzureRouteServer["ars-azure"]
      end

      AzureNvaSubnet["VirtualNetworkApplianceSubnet<br/>172.19.4.0/24"]

      subgraph AzureDnsSubnets["Azure DNS Private Resolver subnets"]
        DnsInbound["dns-resolver-inbound<br/>172.19.5.0/25<br/>inbound IP 172.19.5.4"]
        DnsOutbound["dns-resolver-outbound<br/>172.19.5.128/25"]
      end

      AzureVNetLink["Virtual network links<br/>vnet-azure"]

      subgraph AzureWorkloadSubnets["Firewall-routed workload subnets"]
        Utilities["utilities<br/>172.19.10.0/23"]
        Unisim["unisim<br/>172.19.14.0/28"]
        Dhcp["dhcp<br/>172.19.15.0/28"]
        Live["live<br/>172.19.20.0/23"]
        Avd01["avd01<br/>172.19.40.0/24<br/>vm-azure02 172.19.40.4"]
        ZscalerZpa["zscaler-zpa<br/>172.19.60.0/28"]
        VcpeCorp["vcpe-corp<br/>172.19.80.96/28<br/>vm-azure01 172.19.80.100"]
        VcpeIot["vcpe-iot<br/>172.19.80.112/28"]
      end

      subgraph AzureAdditionalSubnets["Additional workload subnets"]
        VcpeSdwan["vcpe-sdwan<br/>172.19.80.64/28"]
        VmbManagement["vmb-management<br/>172.19.80.80/28"]
        Fw04Untrust["fw04-untrust<br/>172.19.85.32/27"]
        Fw04Management["fw04-management<br/>172.19.85.80/28"]
        Fw04Corp["fw04-corp<br/>172.19.85.96/28"]
        Fw04Iot["fw04-iot<br/>172.19.85.112/28"]
      end

      PrivateDnsZone["Private DNS zone<br/>contoso.azure<br/>registration enabled"]
      DnsRuleset["DNS forwarding ruleset<br/>contoso.onprem -> 10.0.5.4"]
    end
  end

  Internet --- OnPremVgw
  Internet --- AzureVgw
  OnPremVgw <-->|VNet-to-VNet IPsec<br/>cn-vnet-onprem-to-vnet-azure<br/>cn-vnet-azure-to-vnet-onprem| AzureVgw

  GatewayRouteTable -->|Selected Azure prefixes| AzureFirewall
  AzureFirewall -->|Allows inspected subnet traffic| Avd01
  AzureFirewall --> VcpeCorp
  AzureFirewall --> Utilities
  Avd01 -->|UDRs to on-prem and peer workload prefixes| AzureFirewall
  VcpeCorp -->|UDRs to on-prem and peer workload prefixes| AzureFirewall

  DnsOutbound --> DnsRuleset
  DnsRuleset -->|Forward contoso.onprem| OnPremDc
  PrivateDnsZone --- AzureVNetLink
  DnsInbound --- AzureVNetLink

  AzureBastion -.-> Avd01
  AzureBastion -.-> VcpeCorp
  OnPremBastion -.-> OnPremDc
```

## Key Paths

- `vm-azure01` lives in `vcpe-corp` at `172.19.80.100`.
- `vm-azure02` lives in `avd01` at `172.19.40.4`.
- `vm-onprem01` lives in `ad` at `10.0.5.4` and provides AD DS and DNS for `contoso.onprem`.
- Both VPN gateways are active-active because Azure Route Server is deployed in both VNets.
- `rt-gateway-to-firewall-transit` is associated to the Azure `GatewaySubnet` and sends selected Azure destination prefixes from VPN ingress to Azure Firewall.
- The Azure firewall-routed workload subnets have route tables for on-prem and cross-subnet traffic via `afw-azure-standard`.
