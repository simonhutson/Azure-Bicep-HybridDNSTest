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

function New-RouteTableAssociation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubnetName,

        [Parameter(Mandatory = $true)]
        [string]$RouteTableName
    )

    [pscustomobject]@{
        SubnetName = $SubnetName
        RouteTableName = $RouteTableName
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

$routeTableAssociations = @(
    New-RouteTableAssociation -SubnetName 'Workload2Subnet' -RouteTableName 'rt-workload2'
    New-RouteTableAssociation -SubnetName 'Workload1Subnet' -RouteTableName 'rt-workload1'
    New-RouteTableAssociation -SubnetName 'GatewaySubnet' -RouteTableName 'rt-gateway-to-firewall-transit'
)

foreach ($association in $routeTableAssociations) {
    Invoke-AzCliCommand `
        -Description "Checking route table '$($association.RouteTableName)' exists..." `
        -Arguments @('network', 'route-table', 'show', '--resource-group', $ResourceGroupName, '--name', $association.RouteTableName, '--query', 'id', '--output', 'tsv', '--only-show-errors') `
        -ReturnOutput | Out-Null

    Invoke-AzCliCommand `
        -Description "Checking subnet '$($association.SubnetName)' exists..." `
        -Arguments @('network', 'vnet', 'subnet', 'show', '--resource-group', $ResourceGroupName, '--vnet-name', $VirtualNetworkName, '--name', $association.SubnetName, '--query', 'id', '--output', 'tsv', '--only-show-errors') `
        -ReturnOutput | Out-Null
}

foreach ($association in $routeTableAssociations) {
    if ($PSCmdlet.ShouldProcess("$VirtualNetworkName/$($association.SubnetName)", "Associate existing route table '$($association.RouteTableName)'")) {
        Invoke-AzCliCommand `
            -Description "Associating existing route table '$($association.RouteTableName)' to subnet '$($association.SubnetName)'..." `
            -Arguments @('network', 'vnet', 'subnet', 'update', '--resource-group', $ResourceGroupName, '--vnet-name', $VirtualNetworkName, '--name', $association.SubnetName, '--route-table', $association.RouteTableName, '--only-show-errors', '--output', 'none')
    }
}

Write-Host "Reassociated $($routeTableAssociations.Count) existing route table(s) to subnets in '$VirtualNetworkName'. No route table resources or routes were created, updated, or deleted."