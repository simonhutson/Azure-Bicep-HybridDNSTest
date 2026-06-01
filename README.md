# Azure Bicep Hybrid DNS Test

This repository contains a modular Bicep deployment for a hybrid DNS lab using Azure Verified Modules where available.

## What It Deploys

- Resource groups `rg-onprem` and `rg-azure`.
- Simulated on-prem VNet `vnet-onprem` with address space `10.0.0.0/8`.
- Windows Server 2025 Datacenter: Azure Edition domain controller VM `vm-onprem01` on subnet `ad` at `10.0.1.4`.
- Active Directory Domain Services forest and integrated DNS for `contoso.onprem` with configurable NetBIOS name `CONTOSO` by default.
- Simulated Azure VNet `vnet-azure` with address space `172.19.0.0/16`.
- Windows Server 2025 Datacenter: Azure Edition VMs `vm-azure01` and `vm-azure02` on private-only NICs.
- Azure DNS Private Resolver with inbound and outbound endpoint subnets.
- Azure DNS Private Resolver forwarding ruleset linked to `vnet-azure` for forwarding `contoso.onprem` queries to the on-prem DNS server.
- Private DNS zone `contoso.azure`, linked to `vnet-azure` with registration enabled.
- Azure Firewall Standard and Azure Bastion Developer.
- VNet-to-VNet IPsec VPN gateways and bidirectional connections.
- NSGs for the requested custom subnets with only default security rules, including `nsg-dhcp` on `dhcp`.
- No VM NIC creates or attaches a public IP address.

## Files

- [main.bicep](main.bicep): subscription-scope entry point.
- [deploy.ps1](deploy.ps1): PowerShell deployment helper.
- [main.bicepparam](main.bicepparam): optional sample parameters.
- [modules/onprem.bicep](modules/onprem.bicep): simulated on-prem network, Bastion, VPN gateway, and domain controller.
- [modules/azure.bicep](modules/azure.bicep): simulated Azure network, DNS resolver, firewall, Bastion, private DNS zone, and VPN gateway.
- [modules/vpn-connection.bicep](modules/vpn-connection.bicep): reusable VNet-to-VNet IPsec connection module.

## CIDR Corrections

The request included CIDR values that Azure will not accept as written. The template uses deployable defaults:

- `avd01`: `172.19/40.0/24` was corrected to `172.19.40.0/24`.
- `vcpe-corp`: `172.19.80.96.28` was corrected to `172.19.80.96/28`.
- `dhcp`: corrected from invalid and overlapping `172.19.15.0/18` to `172.19.15.0/28`.

The Azure Firewall platform subnets use the explicitly requested non-overlapping ranges:

- `AzureFirewallSubnet`: `172.19.1.0/25`

The `172.19.85.0/24` area is represented by the requested `fw04-*` workload subnets, which would overlap an Azure Firewall platform subnet if both used that same `/24`.

## Deployment

Sign in with Azure CLI, then run the deployment script from the repository root:

```powershell
az login
.\deploy.ps1
```

The script prompts for the secure values, validates the subscription-scope deployment, and then starts the deployment. It uses the current Azure CLI subscription unless `-SubscriptionId` or the `AZURE_SUBSCRIPTION_ID` environment variable is provided. The location defaults to `swedencentral` and can be overridden:

```powershell
.\deploy.ps1 -Location uksouth -SubscriptionId '<subscription-id>'
```

To validate without deploying:

```powershell
.\deploy.ps1 -ValidateOnly
```

To preview changes:

```powershell
.\deploy.ps1 -WhatIf
```

## Notes

- The deployment uses AVM modules for VNets, NSGs, Bastion, Azure Firewall, DNS Resolver, Private DNS, VPN gateways, gateway connections, and the Windows VM.
- The DNS forwarding ruleset sends queries for the on-prem AD DNS namespace to `vm-onprem01` at `10.0.1.4`.
- `vm-onprem01` promotes itself to a domain controller during deployment using the Custom Script Extension, then reboots once to complete AD DS configuration.
- Azure Bastion Developer does not support all Standard/Premium Bastion features. The template intentionally keeps Bastion settings minimal.
- The private DNS zone auto-registers only VMs in `vnet-azure`.
- Bastion, Azure Firewall, and VPN gateways use public IPs where Azure requires them; VM NICs do not.
- Azure Firewall Standard supports threat intelligence alert and deny mode. The template does not enable forced tunneling, so it does not configure a firewall management NIC.
- VPN gateways can take a long time to deploy.
