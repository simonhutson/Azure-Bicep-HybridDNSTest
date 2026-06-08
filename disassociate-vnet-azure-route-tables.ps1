[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ResourceGroupName = 'rg-azure',
    [string]$VirtualNetworkName = 'vnet-azure',
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-AzCliOutputText {
    param(
        [AllowNull()]
        [object[]]$Output
    )

    if (-not $Output) {
        return ''
    }

    return (($Output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
}

function Invoke-AzCliCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Description,

        [switch]$ReturnOutput
    )

    Write-Host $Description
    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $outputText = ConvertTo-AzCliOutputText -Output $output

    if (-not $ReturnOutput -and -not [string]::IsNullOrWhiteSpace($outputText)) {
        Write-Host $outputText
    }

    if ($exitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($outputText)) {
            $outputText = 'Azure CLI did not return additional error output.'
        }

        throw "Azure CLI command failed while: $Description`nExit code: $exitCode`nAzure CLI output:`n$outputText"
    }

    if ($ReturnOutput) {
        return $outputText
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found. Install Azure CLI before running this script.'
}

if ($SubscriptionId) {
    Invoke-AzCliCommand `
        -Description "Selecting subscription '$SubscriptionId'..." `
        -Arguments @('account', 'set', '--subscription', $SubscriptionId, '--only-show-errors')
}

Invoke-AzCliCommand `
    -Description "Checking virtual network '$VirtualNetworkName' in resource group '$ResourceGroupName'..." `
    -Arguments @('network', 'vnet', 'show', '--resource-group', $ResourceGroupName, '--name', $VirtualNetworkName, '--only-show-errors', '--output', 'none')

$subnetsJson = Invoke-AzCliCommand `
    -Description "Finding subnet route table associations in '$VirtualNetworkName'..." `
    -Arguments @('network', 'vnet', 'subnet', 'list', '--resource-group', $ResourceGroupName, '--vnet-name', $VirtualNetworkName, '--query', '[].{name:name,routeTableId:routeTable.id}', '--output', 'json', '--only-show-errors') `
    -ReturnOutput

$subnets = @()
if (-not [string]::IsNullOrWhiteSpace($subnetsJson)) {
    $subnets = @(ConvertFrom-Json -InputObject $subnetsJson)
}

$associatedSubnets = @($subnets | Where-Object { -not [string]::IsNullOrWhiteSpace($_.routeTableId) })
if ($associatedSubnets.Count -eq 0) {
    Write-Host "No route tables are associated with subnets in '$VirtualNetworkName'."
    return
}

foreach ($subnet in $associatedSubnets) {
    $routeTableName = ($subnet.routeTableId -split '/')[-1]
    if ($PSCmdlet.ShouldProcess("$VirtualNetworkName/$($subnet.name)", "Remove route table association '$routeTableName'")) {
        Invoke-AzCliCommand `
            -Description "Removing route table association '$routeTableName' from subnet '$($subnet.name)'..." `
            -Arguments @('network', 'vnet', 'subnet', 'update', '--resource-group', $ResourceGroupName, '--vnet-name', $VirtualNetworkName, '--name', $subnet.name, '--remove', 'routeTable', '--only-show-errors', '--output', 'none')
    }
}

Write-Host "Removed route table associations from $($associatedSubnets.Count) subnet(s) in '$VirtualNetworkName'. Route table resources were left in place."