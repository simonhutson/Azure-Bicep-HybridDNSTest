# Azure Bicep Hybrid DNS Test

This repository contains a modular Bicep deployment for a hybrid DNS lab using Azure Verified Modules where available.

## What It Deploys

- Resource groups `rg-onprem` and `rg-azure`.
- Simulated on-prem VNet `vnet-onprem` with address space `10.0.0.0/8`.
- Windows Server 2025 Datacenter: Azure Edition domain controller VM `vm-onprem01` on subnet `ActiveDirectorySubnet` at `10.0.11.4`.
- Active Directory Domain Services forest and integrated DNS for `contoso.onprem` with configurable NetBIOS name `CONTOSO` by default.
- Simulated Azure VNet `vnet-azure` with address space `172.16.0.0/16`.
- Windows Server 2025 Datacenter: Azure Edition VMs `vm-azure01` at `172.16.11.100` and `vm-azure02` at `172.16.12.4` on private-only NICs, configured with a Private Windows network profile and inbound ICMP allowed in Windows Firewall.
- All Windows VMs use the Hyper-V Generation 2 Windows Server 2025 Azure Edition image and Trusted Launch with Secure Boot and vTPM enabled.
- Azure Route Server in both `vnet-onprem` and `vnet-azure`.
- NAT gateways `ngw-onprem` and `ngw-azure`, each with a Standard static public IP for private workload outbound SNAT.
- Azure DNS Private Resolver with inbound endpoint `172.16.5.4` and outbound endpoint subnet.
- Azure DNS Private Resolver forwarding ruleset linked to `vnet-azure` for forwarding `contoso.onprem` queries to the on-prem DNS server.
- DNS conditional forwarder on `vm-onprem01` for `contoso.azure`, forwarding to the Azure DNS Private Resolver inbound endpoint.
- Private DNS zone `contoso.azure`, linked to `vnet-azure` with registration enabled.
- Azure Firewall Standard and Azure Bastion Developer.
- Dedicated NSGs for each `AzureBastionSubnet` with the Microsoft-documented Azure Bastion inbound and outbound rules.
- Azure route tables that force Azure-to-on-prem and on-prem-to-Azure traffic through Azure Firewall while workload subnet-to-subnet traffic uses VNet local routing.
- Active-active VNet-to-VNet IPsec VPN gateways and bidirectional connections.
- NSGs for `Workload1Subnet` and `Workload2Subnet` with only default security rules.
- No VM NIC creates or attaches a public IP address.

## Files

- [main.bicep](main.bicep): subscription-scope entry point.
- [deploy.ps1](deploy.ps1): PowerShell deployment helper.
- [main.bicepparam](main.bicepparam): optional sample parameters.
- [modules/onprem.bicep](modules/onprem.bicep): simulated on-prem network, Bastion, VPN gateway, and domain controller.
- [modules/azure.bicep](modules/azure.bicep): simulated Azure network, DNS resolver, firewall, Bastion, private DNS zone, and VPN gateway.
- [modules/vpn-connection.bicep](modules/vpn-connection.bicep): reusable VNet-to-VNet IPsec connection module.

## Subnet Addressing

The template uses these Azure workload subnet ranges:

- `Workload1Subnet`: `172.16.11.0/24`.
- `Workload2Subnet`: `172.16.12.0/24`.

The platform subnets use non-overlapping ranges reserved for Azure services and future route-server testing:

- On-prem `GatewaySubnet`: `10.0.0.0/24`
- On-prem `AzureBastionSubnet`: `10.0.1.0/24`
- On-prem `AzureFirewallSubnet`: `10.0.2.0/24`
- On-prem `RouteServerSubnet`: `10.0.3.0/24`
- On-prem `VirtualNetworkApplianceSubnet`: `10.0.4.0/24`
- On-prem `ActiveDirectorySubnet`: `10.0.11.0/24`
- Azure `GatewaySubnet`: `172.16.0.0/24`
- Azure `AzureBastionSubnet`: `172.16.1.0/24`
- Azure `AzureFirewallSubnet`: `172.16.2.0/24`
- Azure `RouteServerSubnet`: `172.16.3.0/24`
- Azure `VirtualNetworkApplianceSubnet`: `172.16.4.0/24`
- Azure `DnsPrivateResolverInboundSubnet`: `172.16.5.0/24`
- Azure `DnsPrivateResolverOutboundSubnet`: `172.16.6.0/24`

## Deployment

Sign in with Azure CLI, then run the deployment script from the repository root:

```powershell
az login
.\deploy.ps1
```

The script prompts for the secure values, validates the subscription-scope deployment, and then starts the deployment. It uses the current Azure CLI subscription unless `-SubscriptionId` or the `AZURE_SUBSCRIPTION_ID` environment variable is provided. The location defaults to `swedencentral` and can be overridden:

```powershell
.\deploy.ps1 -Location swedencentral -SubscriptionId '<subscription-id>'
```

The VM size defaults to `Standard_D4ads_v5` and can be overridden:

```powershell
.\deploy.ps1 -VmSize 'Standard_D4ads_v5'
```

The Active Directory DNS domain name defaults to `contoso.onprem` and can be overridden along with the NetBIOS name:

```powershell
.\deploy.ps1 -ActiveDirectoryDomainName 'corp.example' -ActiveDirectoryNetbiosName 'CORP'
```

The Azure private DNS zone defaults to `contoso.azure`, and `vm-onprem01` is configured with a matching conditional forwarder to the DNS Private Resolver inbound endpoint:

```powershell
.\deploy.ps1 -PrivateDnsZoneName 'contoso.azure' -DnsResolverInboundEndpointPrivateIpAddress '172.16.5.4'
```

To validate without deploying:

```powershell
.\deploy.ps1 -ValidateOnly
```

If the domain controller promotion is unusually slow, the post-deployment readiness wait can be extended:

```powershell
.\deploy.ps1 -DomainControllerReadyTimeoutMinutes 90
```

To preview changes:

```powershell
.\deploy.ps1 -WhatIf
```

## Notes

- The deployment uses AVM modules for VNets, NSGs, Bastion, Private DNS, VPN gateways, gateway connections, and the Windows VM. Azure Firewall and DNS Resolver resources are deployed directly where the template needs tighter control.
- The DNS forwarding ruleset sends queries for the on-prem AD DNS namespace to `vm-onprem01` at `10.0.11.4`.
- `vm-onprem01` has a DNS conditional forwarder for the Azure private DNS zone that targets the DNS Private Resolver inbound endpoint.
- If Azure DNS Private Resolver returns a forwarding ruleset VNet link circuit-breaker error, `deploy.ps1` deletes the stale `link-vnet-azure` link and retries the deployment once.
- `vm-onprem01` promotes itself to a domain controller during deployment using the Custom Script Extension, sets its Windows network profile to Private, allows inbound ICMP in Windows Firewall, then reboots once to complete AD DS configuration. `deploy.ps1` waits for the VM to report that the Active Directory forest is ready before it exits.
- Azure Bastion Developer does not support all Standard/Premium Bastion features. The template intentionally keeps Bastion settings minimal.
- The private DNS zone auto-registers only VMs in `vnet-azure`.
- Bastion, Azure Firewall, VPN gateways, Route Server, and NAT gateways use public IPs where Azure requires them; VM NICs do not.
- Azure Firewall Standard supports threat intelligence alert and deny mode. The template does not enable forced tunneling, so it does not configure a firewall management NIC.
- `RouteServerSubnet` subnets intentionally do not associate NSGs because Azure Route Server does not support NSGs on that subnet.
- `AzureBastionSubnet` subnets use dedicated NSGs with the rules documented for Azure Bastion.
- VPN gateways are deployed in active-active mode because Azure Route Server is present in both VNets; Azure does not support active-passive VPN gateways in that topology. Gateways can take a long time to deploy.
