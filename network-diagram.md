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

      subgraph OnPremAdSubnet["ActiveDirectorySubnet<br/>10.0.11.0/24"]
        OnPremDc["vm-onprem01<br/>10.0.11.4<br/>AD DS + DNS"]
      end
    end

    OnPremNat["ngw-onprem<br/>pip-ngw-onprem"]
  end

  subgraph AzureRG["rg-azure"]
    subgraph AzureVNet["vnet-azure<br/>172.16.0.0/16"]
      subgraph AzureGatewaySubnet["GatewaySubnet<br/>172.16.0.0/24"]
        AzureVgw["vgw-azure<br/>VpnGw1AZ<br/>active-active"]
        GatewayRouteTable["rt-gateway-to-firewall-transit"]
      end

      subgraph AzureBastionSubnet["AzureBastionSubnet<br/>172.16.1.0/24"]
        AzureBastion["bas-azure-dev"]
      end

      subgraph AzureFirewallSubnet["AzureFirewallSubnet<br/>172.16.2.0/24"]
        AzureFirewall["afw-azure-standard<br/>Azure Firewall Standard"]
      end

      subgraph AzureRouteServerSubnet["RouteServerSubnet<br/>172.16.3.0/24"]
        AzureRouteServer["ars-azure"]
      end

      AzureNvaSubnet["VirtualNetworkApplianceSubnet<br/>172.16.4.0/24"]

      subgraph AzureDnsSubnets["Azure DNS Private Resolver subnets"]
        DnsInbound["DnsPrivateResolverInboundSubnet<br/>172.16.5.0/24<br/>inbound IP 172.16.5.4"]
        DnsOutbound["DnsPrivateResolverOutboundSubnet<br/>172.16.6.0/24"]
      end

      AzureVNetLink["Virtual network links<br/>vnet-azure"]

      subgraph AzureWorkloadSubnets["Firewall-routed workload subnets"]
        Workload2["Workload2Subnet<br/>172.16.12.0/24<br/>vm-azure02 172.16.12.4"]
        Workload1["Workload1Subnet<br/>172.16.11.0/24<br/>vm-azure01 172.16.11.100"]
      end

      PrivateDnsZone["Private DNS zone<br/>contoso.azure<br/>registration enabled"]
      DnsRuleset["DNS forwarding ruleset<br/>contoso.onprem -> 10.0.11.4"]
    end

    AzureNat["ngw-azure<br/>pip-ngw-azure"]
  end

  Internet --- OnPremVgw
  Internet --- AzureVgw
  OnPremAdSubnet -->|Outbound SNAT| OnPremNat
  OnPremNat --> Internet
  AzureWorkloadSubnets -->|Outbound SNAT| AzureNat
  AzureNat --> Internet
  OnPremVgw <-->|VNet-to-VNet IPsec<br/>cn-vnet-onprem-to-vnet-azure<br/>cn-vnet-azure-to-vnet-onprem| AzureVgw

  GatewayRouteTable -->|Selected Azure prefixes| AzureFirewall
  AzureFirewall -->|Inspected on-prem ingress| Workload2
  AzureFirewall --> Workload1
  Workload2 -->|UDR to on-prem| AzureFirewall
  Workload1 -->|UDR to on-prem| AzureFirewall
  Workload1 <-->|VNet local routing| Workload2

  DnsOutbound --> DnsRuleset
  DnsRuleset -->|Forward contoso.onprem| OnPremDc
  PrivateDnsZone --- AzureVNetLink
  DnsInbound --- AzureVNetLink

  AzureBastion -.-> Workload2
  AzureBastion -.-> Workload1
  OnPremBastion -.-> OnPremDc
```

## Key Paths

- `vm-azure01` lives in `Workload1Subnet` at `172.16.11.100`.
- `vm-azure02` lives in `Workload2Subnet` at `172.16.12.4`.
- `vm-onprem01` lives in `ActiveDirectorySubnet` at `10.0.11.4` and provides AD DS and DNS for `contoso.onprem`.
- Both VPN gateways are active-active because Azure Route Server is deployed in both VNets.
- `ngw-onprem` is associated to the on-prem `ActiveDirectorySubnet` and `ngw-azure` is associated to the Azure custom workload subnets for outbound SNAT.
- `rt-gateway-to-firewall-transit` is associated to the Azure `GatewaySubnet` and sends selected Azure destination prefixes from VPN ingress to Azure Firewall.
- The Azure workload subnets route on-prem traffic via `afw-azure-standard`; workload subnet-to-subnet traffic uses VNet local routing.
