# Azure Bicep Hybrid DNS Test

This repository contains a modular Bicep deployment for a hybrid DNS lab using Azure Verified Modules where available.

## What It Deploys

- Resource groups `rg-on-premises` and `rg-azure`.
- Simulated on-premises VNet `vnet-on-premises` with address space `10.0.0.0/8`.
- Windows Server domain controller VM `ad01` on subnet `ad` at `10.0.1.4`.
- Active Directory Domain Services forest and integrated DNS for `viridor.local`.
- Simulated Azure VNet `vnet-vwm01` with address space `172.19.0.0/16`.
- Azure DNS Private Resolver with inbound and outbound endpoint subnets.
- Private DNS zone `viridor.local`, linked to `vnet-vwm01` with registration enabled.
- Azure Firewall Basic and Azure Bastion Developer.
- VNet-to-VNet IPsec VPN gateways and bidirectional connections.
- NSGs for the requested custom subnets with only default security rules, including `nsg-dhcp` on `dhcp`.

## Files

- [main.bicep](main.bicep): subscription-scope entry point.
- [deploy.ps1](deploy.ps1): PowerShell deployment helper.
- [main.bicepparam](main.bicepparam): optional sample parameters.
- [modules/on-premises.bicep](modules/on-premises.bicep): simulated on-premises network, Bastion, VPN gateway, and domain controller.
- [modules/azure.bicep](modules/azure.bicep): simulated Azure network, DNS resolver, firewall, Bastion, private DNS zone, and VPN gateway.
- [modules/vpn-connection.bicep](modules/vpn-connection.bicep): reusable VNet-to-VNet IPsec connection module.

## CIDR Corrections

The request included CIDR values that Azure will not accept as written. The template uses deployable defaults:

- `avd01`: `172.19/40.0/24` was corrected to `172.19.40.0/24`.
- `vcpe-corp`: `172.19.80.96.28` was corrected to `172.19.80.96/28`.
- `dhcp`: corrected from invalid and overlapping `172.19.15.0/18` to `172.19.15.0/28`.

The requested `172.19.85.0/24` Azure Firewall area overlaps the `fw04-*` subnets, so the deployable Azure Firewall platform subnets are carved from that range as:

- `AzureFirewallSubnet`: `172.19.85.0/26`
- `AzureFirewallManagementSubnet`: `172.19.85.128/26`

## Deployment

Sign in with Azure CLI, then run the deployment script from the repository root:

```powershell
az login
.\deploy.ps1
```

The script prompts for the secure values, validates the subscription-scope deployment, and then starts the deployment. It defaults to `swedencentral` and can be overridden:

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
- Azure Bastion Developer does not support all Standard/Premium Bastion features. The template intentionally keeps Bastion settings minimal.
- The private DNS zone auto-registers VMs in `vnet-vwm01`. The `ad01` record is created explicitly because `ad01` lives in the simulated on-premises VNet.
- VPN gateways can take a long time to deploy.
