# Azure Bicep Hybrid DNS Test

This repository contains a modular Bicep deployment for a hybrid DNS lab using Azure Verified Modules where available.

## What It Deploys

- Resource groups `rg-onprem` and `rg-azure`.
- Simulated on-prem VNet `vnet-onprem` with address space `10.0.0.0/8`.
- Windows Server 2025 Datacenter: Azure Edition domain controller VM `vm-onprem01` on subnet `ad` at `10.0.5.4`.
- Active Directory Domain Services forest and integrated DNS for `contoso.onprem` with configurable NetBIOS name `CONTOSO` by default.
- Simulated Azure VNet `vnet-azure` with address space `172.19.0.0/16`.
- Windows Server 2025 Datacenter: Azure Edition VMs `vm-azure01` at `172.19.80.100` and `vm-azure02` at `172.19.40.4` on private-only NICs, configured with a Private Windows network profile and inbound ICMP allowed in Windows Firewall.
- Azure Route Server in both `vnet-onprem` and `vnet-azure`.
- Azure DNS Private Resolver with inbound endpoint `172.19.5.4` and outbound endpoint subnet.
- Azure DNS Private Resolver forwarding ruleset linked to `vnet-azure` for forwarding `contoso.onprem` queries to the on-prem DNS server.
- Private DNS zone `contoso.azure`, linked to `vnet-azure` with registration enabled.
- Azure Firewall Standard and Azure Bastion Developer.
- Dedicated NSGs for each `AzureBastionSubnet` with the Microsoft-documented Azure Bastion inbound and outbound rules.
- Azure Compute Gallery VM Application definition for an Ubuntu SD-WAN/router-style appliance bootstrap package.
- Azure route tables that force requested Azure subnet-to-subnet traffic and on-prem ingress through Azure Firewall.
- Active-active VNet-to-VNet IPsec VPN gateways and bidirectional connections.
- NSGs for the requested custom subnets with only default security rules, including `nsg-dhcp` on `dhcp`.
- No VM NIC creates or attaches a public IP address.

## Files

- [main.bicep](main.bicep): subscription-scope entry point.
- [deploy.ps1](deploy.ps1): PowerShell deployment helper.
- [disassociate-vnet-azure-route-tables.ps1](disassociate-vnet-azure-route-tables.ps1): standalone helper to disassociate route tables from `vnet-azure` subnets.
- [associate-vnet-azure-route-tables.ps1](associate-vnet-azure-route-tables.ps1): standalone helper to associate the existing `vnet-azure` route tables to their expected subnets.
- [main.bicepparam](main.bicepparam): optional sample parameters.
- [modules/onprem.bicep](modules/onprem.bicep): simulated on-prem network, Bastion, VPN gateway, and domain controller.
- [modules/azure.bicep](modules/azure.bicep): simulated Azure network, DNS resolver, firewall, Bastion, private DNS zone, and VPN gateway.
- [modules/ubuntu-router-vm-application.bicep](modules/ubuntu-router-vm-application.bicep): Azure Compute Gallery VM Application for the Ubuntu router appliance package.
- [modules/vpn-connection.bicep](modules/vpn-connection.bicep): reusable VNet-to-VNet IPsec connection module.
- [vm-applications/ubuntu-sdwan-router](vm-applications/ubuntu-sdwan-router): install, update, and remove scripts packaged for the Ubuntu router VM Application.

## CIDR Corrections

The request included CIDR values that Azure will not accept as written. The template uses deployable defaults:

- `avd01`: `172.19/40.0/24` was corrected to `172.19.40.0/24`.
- `vcpe-corp`: `172.19.80.96.28` was corrected to `172.19.80.96/28`.
- `dhcp`: corrected from invalid and overlapping `172.19.15.0/18` to `172.19.15.0/28`.

The platform subnets use non-overlapping ranges reserved for Azure services and future route-server testing:

- On-prem `GatewaySubnet`: `10.0.0.0/24`
- On-prem `AzureBastionSubnet`: `10.0.1.0/24`
- On-prem `AzureFirewallSubnet`: `10.0.2.0/24`
- On-prem `RouteServerSubnet`: `10.0.3.0/24`
- On-prem `VirtualNetworkApplianceSubnet`: `10.0.4.0/24`
- On-prem `ad`: `10.0.5.0/24`
- Azure `GatewaySubnet`: `172.19.0.0/24`
- Azure `AzureBastionSubnet`: `172.19.1.0/24`
- Azure `AzureFirewallSubnet`: `172.19.2.0/24`
- Azure `RouteServerSubnet`: `172.19.3.0/24`
- Azure `VirtualNetworkApplianceSubnet`: `172.19.4.0/24`
- Azure DNS resolver subnets: `172.19.5.0/25` and `172.19.5.128/25`

The `172.19.85.0/24` area is represented by the requested `fw04-*` workload subnets, which would overlap an Azure Firewall platform subnet if both used that same `/24`.

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

The VM size defaults to `Standard_D2ads_v5` and can be overridden:

```powershell
.\deploy.ps1 -VmSize 'Standard_D4ads_v5'
```

The Active Directory DNS domain name defaults to `contoso.onprem` and can be overridden along with the NetBIOS name:

```powershell
.\deploy.ps1 -ActiveDirectoryDomainName 'corp.example' -ActiveDirectoryNetbiosName 'CORP'
```

The Ubuntu SD-WAN/router VM Application creates the gallery and application by default. During a real deployment, the script packages the local artifact, creates or reuses a private blob container in `rg-azure`, uploads the zip with Microsoft Entra authentication, generates a temporary read-only user delegation SAS URI, and passes it to the deployment:

```powershell
.\deploy.ps1
```

The storage account name is generated from the subscription and resource group by default. You can override the package storage settings or provide your own reachable package URI:

```powershell
.\deploy.ps1 -VmApplicationPackageStorageAccountName '<storage-account-name>'
.\deploy.ps1 -UbuntuRouterVmApplicationPackageUri '<https-package-uri>'
```

For `-ValidateOnly` and `-WhatIf`, the script skips automatic packaging/upload unless `-UbuntuRouterVmApplicationPackageUri` is provided.

The signed-in Azure CLI principal needs blob data-plane rights such as `Storage Blob Data Contributor` on the package storage account or containing scope for the automatic upload and user delegation SAS generation. The script tries to assign `Storage Blob Data Contributor` on the package storage account automatically, then retries storage data-plane operations for up to five minutes while RBAC propagates. Use `-SkipVmApplicationStorageRoleAssignment` if you manage that role assignment separately, or `-VmApplicationStorageRolePropagationWaitSeconds` to adjust the propagation wait.

To validate without deploying:

```powershell
.\deploy.ps1 -ValidateOnly
```

To preview changes:

```powershell
.\deploy.ps1 -WhatIf
```

To temporarily remove the route table associations from all `vnet-azure` subnets and then reassociate the existing lab route tables:

```powershell
.\disassociate-vnet-azure-route-tables.ps1
.\associate-vnet-azure-route-tables.ps1
```

## Notes

- The deployment uses AVM modules for VNets, NSGs, Bastion, Private DNS, VPN gateways, gateway connections, and the Windows VM. Azure Firewall and DNS Resolver resources are deployed directly where the template needs tighter control.
- The DNS forwarding ruleset sends queries for the on-prem AD DNS namespace to `vm-onprem01` at `10.0.5.4`.
- `vm-onprem01` promotes itself to a domain controller during deployment using the Custom Script Extension, sets its Windows network profile to Private, allows inbound ICMP in Windows Firewall, then reboots once to complete AD DS configuration. `deploy.ps1` waits for the VM to report that the Active Directory forest is ready before it exits.
- Azure Bastion Developer does not support all Standard/Premium Bastion features. The template intentionally keeps Bastion settings minimal.
- The Ubuntu router VM Application package installs FRR, WireGuard, strongSwan, and forwarding defaults. It does not configure BGP peers, tunnel keys, or route policy.
- The private DNS zone auto-registers only VMs in `vnet-azure`.
- Bastion, Azure Firewall, and VPN gateways use public IPs where Azure requires them; VM NICs do not.
- Azure Firewall Standard supports threat intelligence alert and deny mode. The template does not enable forced tunneling, so it does not configure a firewall management NIC.
- `RouteServerSubnet` subnets intentionally do not associate NSGs because Azure Route Server does not support NSGs on that subnet.
- `AzureBastionSubnet` subnets use dedicated NSGs with the rules documented for Azure Bastion.
- VPN gateways are deployed in active-active mode because Azure Route Server is present in both VNets; Azure does not support active-passive VPN gateways in that topology. Gateways can take a long time to deploy.
