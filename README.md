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
- Azure Firewall Basic and Azure Bastion Developer in both VNets.
- VNet-to-VNet IPsec VPN gateways and bidirectional connections.
- NSGs for the requested custom subnets with only default security rules.

## Files

- [main.bicep](main.bicep): subscription-scope entry point.
- [main.bicepparam](main.bicepparam): sample parameters.
- [modules/on-premises.bicep](modules/on-premises.bicep): simulated on-premises network, Bastion, VPN gateway, and domain controller.
- [modules/azure.bicep](modules/azure.bicep): simulated Azure network, DNS resolver, firewall, Bastion, private DNS zone, and VPN gateway.
- [modules/vpn-connection.bicep](modules/vpn-connection.bicep): reusable VNet-to-VNet IPsec connection module.

## CIDR Corrections

The request included three CIDR values that Azure will not accept as written. The template uses deployable defaults:

- `avd01`: `172.19/40.0/24` was corrected to `172.19.40.0/24`.
- `vcpe-corp`: `172.19.80.96.28` was corrected to `172.19.80.96/28`.
- `dhcp`: corrected from invalid and overlapping `172.19.15.0/18` to `172.19.15.0/28`.

The requested `172.19.85.0/24` Azure Firewall area overlaps the `fw04-*` subnets, so the deployable Azure Firewall platform subnets are carved from that range as:

- `AzureFirewallSubnet`: `172.19.85.0/26`
- `AzureFirewallManagementSubnet`: `172.19.85.128/26`

## Deployment

Update [main.bicepparam](main.bicepparam) with strong values for the secure parameters, then deploy at subscription scope:

```powershell
az deployment sub create `
  --location uksouth `
  --template-file main.bicep `
  --parameters main.bicepparam
```

You can also pass secure parameters at deployment time instead of storing them in the parameter file.

## Notes

- The deployment uses AVM modules for VNets, NSGs, Bastion, Azure Firewall, DNS Resolver, Private DNS, VPN gateways, gateway connections, and the Windows VM.
- Azure Bastion Developer does not support all Standard/Premium Bastion features. The template intentionally keeps Bastion settings minimal.
- The private DNS zone auto-registers VMs in `vnet-vwm01`. The `ad01` record is created explicitly because `ad01` lives in the simulated on-premises VNet.
- VPN gateways can take a long time to deploy.
# Azure Bicep Hybrid DNS Test

This repo contains a modular Bicep deployment for a hybrid DNS test environment using Azure Verified Modules where available.

## What It Deploys

- `rg-on-premises`
  - `vnet-on-premises` with `10.0.0.0/8`
  - `ad` subnet with `ad01`, a Windows Server VM promoted to an AD DS domain controller with integrated DNS for `viridor.local`
  - Azure Bastion Developer SKU
  - VPN gateway for VNet-to-VNet IPsec connectivity
  - `nsg-ad` with only Azure default security rules

- `rg-azure`
  - `vnet-vwm01` with `172.19.0.0/16`
  - Azure DNS Private Resolver with inbound and outbound endpoints
  - Private DNS zone `viridor.local`, linked to both VNets and configured for VM auto-registration on `vnet-vwm01`
  - Azure Firewall Basic SKU
  - Azure Bastion Developer SKU
  - VPN gateway and reciprocal VPN connection
  - Requested custom NSGs with only Azure default security rules

## Address Plan Notes

Several requested CIDRs were malformed or overlapping. The defaults in [main.bicep](main.bicep) keep the requested subnet names but use deployable CIDRs:

- `avd01`: corrected from `172.19/40.0/24` to `172.19.40.0/24`.
- `vcpe-corp`: corrected from `172.19.80.96.28` to `172.19.80.96/28`.
- `dhcp`: changed from invalid and overlapping `172.19.15.0/18` to `172.19.15.0/28`.
- `AzureFirewallSubnet`: placed at `172.19.86.0/26` because `172.19.85.0/24` overlaps the requested `fw04-*` subnets and Azure Firewall requires a dedicated `AzureFirewallSubnet`.
- Duplicate `nsg-fw04-corp` was created once.

Override `azureSubnets` or `onPremisesSubnets` at deployment time if you want a different validated address plan.

## Deploy

Set the secure values as environment variables, then deploy at subscription scope:

```powershell
$env:ADMIN_PASSWORD = '<complex-password>'
$env:VPN_SHARED_KEY = '<vpn-shared-key>'

az deployment sub create `
  --location uksouth `
  --template-file main.bicep `
  --parameters main.bicepparam
```

The AD DS promotion uses the VM admin password as the DSRM password because this is a disposable test environment.

## Modules

- [modules/networkSecurityGroups.bicep](modules/networkSecurityGroups.bicep)
- [modules/virtualNetwork.bicep](modules/virtualNetwork.bicep)
- [modules/bastionDeveloper.bicep](modules/bastionDeveloper.bicep)
- [modules/domainController.bicep](modules/domainController.bicep)
- [modules/privateDns.bicep](modules/privateDns.bicep)
- [modules/dnsResolver.bicep](modules/dnsResolver.bicep)
- [modules/firewall.bicep](modules/firewall.bicep)
- [modules/vpnGateway.bicep](modules/vpnGateway.bicep)
- [modules/vpnConnection.bicep](modules/vpnConnection.bicep)