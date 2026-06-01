[CmdletBinding()]
param(
    [string]$Location = 'swedencentral',
    [string]$DeploymentName = ('hybrid-dns-{0:yyyyMMdd-HHmmss}' -f (Get-Date)),
    [string]$TemplateFile = (Join-Path $PSScriptRoot 'main.bicep'),
    [string]$OnPremisesResourceGroupName = 'rg-on-premises',
    [string]$AzureResourceGroupName = 'rg-azure',
    [string]$AdminUsername = 'azureadmin',
    [string]$PrivateDnsZoneName = 'viridor.local',
    [string]$SubscriptionId,
    [securestring]$AdminPassword,
    [securestring]$DomainSafeModeAdminPassword,
    [securestring]$VpnSharedKey,
    [switch]$ValidateOnly,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-PlainText {
    param(
        [Parameter(Mandatory = $true)]
        [securestring]$SecureValue
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Invoke-AzDeploymentCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    Write-Host $Description
    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed with exit code $LASTEXITCODE."
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found. Install Azure CLI before running this script.'
}

if (-not (Test-Path -Path $TemplateFile -PathType Leaf)) {
    throw "Template file not found: $TemplateFile"
}

$null = & az account show --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'Azure CLI is not signed in. Run az login, then rerun this script.'
}

if ($SubscriptionId) {
    Invoke-AzDeploymentCommand `
        -Description "Selecting subscription $SubscriptionId..." `
        -Arguments @('account', 'set', '--subscription', $SubscriptionId)
}

if (-not $AdminPassword) {
    $AdminPassword = Read-Host -Prompt 'VM administrator password' -AsSecureString
}

if (-not $DomainSafeModeAdminPassword) {
    $DomainSafeModeAdminPassword = Read-Host -Prompt 'Directory Services Restore Mode password' -AsSecureString
}

if (-not $VpnSharedKey) {
    $VpnSharedKey = Read-Host -Prompt 'VPN shared key' -AsSecureString
}

$tempParametersFile = Join-Path ([IO.Path]::GetTempPath()) ('hybrid-dns-parameters-{0}.json' -f ([Guid]::NewGuid()))

try {
    $deploymentParameters = [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = [ordered]@{
            location = @{ value = $Location }
            onPremisesResourceGroupName = @{ value = $OnPremisesResourceGroupName }
            azureResourceGroupName = @{ value = $AzureResourceGroupName }
            adminUsername = @{ value = $AdminUsername }
            adminPassword = @{ value = (ConvertTo-PlainText -SecureValue $AdminPassword) }
            domainSafeModeAdminPassword = @{ value = (ConvertTo-PlainText -SecureValue $DomainSafeModeAdminPassword) }
            vpnSharedKey = @{ value = (ConvertTo-PlainText -SecureValue $VpnSharedKey) }
            privateDnsZoneName = @{ value = $PrivateDnsZoneName }
            tags = @{
                value = @{
                    workload = 'hybrid-dns-test'
                    environment = 'lab'
                }
            }
        }
    }

    $deploymentParameters |
        ConvertTo-Json -Depth 10 |
        Set-Content -Path $tempParametersFile -Encoding utf8 -NoNewline

    $commonArguments = @(
        '--location', $Location,
        '--name', $DeploymentName,
        '--template-file', $TemplateFile,
        '--parameters', "@$tempParametersFile"
    )

    Invoke-AzDeploymentCommand `
        -Description "Validating subscription deployment '$DeploymentName' in $Location..." `
        -Arguments (@('deployment', 'sub', 'validate') + $commonArguments)

    if ($ValidateOnly) {
        Write-Host 'Validation completed. Deployment was not started because -ValidateOnly was specified.'
        return
    }

    if ($WhatIf) {
        Invoke-AzDeploymentCommand `
            -Description "Running what-if for subscription deployment '$DeploymentName' in $Location..." `
            -Arguments (@('deployment', 'sub', 'what-if') + $commonArguments)
        return
    }

    Invoke-AzDeploymentCommand `
        -Description "Starting subscription deployment '$DeploymentName' in $Location..." `
        -Arguments (@('deployment', 'sub', 'create') + $commonArguments)
}
finally {
    if (Test-Path -Path $tempParametersFile -PathType Leaf) {
        Remove-Item -Path $tempParametersFile -Force
    }
}
