# Ubuntu SD-WAN Router VM Application

This package bootstraps an Ubuntu VM into a router-style appliance baseline for lab use.

It installs:

- FRRouting for BGP and dynamic routing simulation.
- WireGuard for lightweight overlay tunnels.
- strongSwan for IPsec tunnel simulation.
- Supporting network troubleshooting tools.
- Linux forwarding sysctl defaults.

The package intentionally does not configure peers, tunnel keys, route maps, or customer-specific policies. Apply those as VM-specific configuration after the baseline package is installed.

The repository deployment script packages this directory automatically during a real deployment. It creates or reuses a private blob container, uploads the zip archive with Microsoft Entra authentication, generates a temporary read-only user delegation SAS URI, and passes that URI to the Azure VM Application version.

To package manually:

```powershell
Compress-Archive -Path .\vm-applications\ubuntu-sdwan-router\* -DestinationPath .\ubuntu-sdwan-router-1.0.0.zip -Force
```

Upload the archive to a storage location reachable by Azure Compute Gallery, then pass the archive URI to `ubuntuRouterVmApplicationPackageUri` or `-UbuntuRouterVmApplicationPackageUri`.