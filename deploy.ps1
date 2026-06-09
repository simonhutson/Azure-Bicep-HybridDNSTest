[CmdletBinding()]
param(
    [string]$Location = 'swedencentral',
    [string]$DeploymentName = ('hybrid-dns-{0:yyyyMMdd-HHmmss}' -f (Get-Date)),
    [string]$TemplateFile = (Join-Path $PSScriptRoot 'main.bicep'),
    [string]$OnPremResourceGroupName = 'rg-onprem',
    [string]$AzureResourceGroupName = 'rg-azure',
    [string]$AdminUsername = 'azureadmin',
    [string]$VmSize = 'Standard_D4ads_v5',
    [string]$PrivateDnsZoneName = 'contoso.azure',
    [string]$ActiveDirectoryDomainName = 'contoso.onprem',
    [ValidateLength(1, 15)]
    [string]$ActiveDirectoryNetbiosName = 'CONTOSO',
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [securestring]$AdminPassword,
    [securestring]$DomainSafeModeAdminPassword,
    [securestring]$VpnSharedKey,
    [switch]$ValidateOnly,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$deployScriptVersion = '2026-06-09.2'
$dnsForwardingRulesetName = 'dnsfrs-azure-to-onprem'
$dnsForwardingRulesetVirtualNetworkLinkName = 'link-vnet-azure'
$dnsForwardingRulesetApiVersion = '2025-05-01'

Write-Host "Running deploy.ps1 version $deployScriptVersion from '$PSCommandPath'."

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

function New-AzCliFailureMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Description,

        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [AllowNull()]
        [object[]]$Output
    )

    $outputText = ConvertTo-AzCliOutputText -Output $Output
    if ([string]::IsNullOrWhiteSpace($outputText)) {
        $outputText = 'Azure CLI did not return additional error output.'
    }

    return "Azure CLI command failed while: $Description`nExit code: $ExitCode`nAzure CLI output:`n$outputText"
}

function Write-AzCliOutput {
    param(
        [AllowNull()]
        [object[]]$Output
    )

    $outputText = ConvertTo-AzCliOutputText -Output $Output
    if (-not [string]::IsNullOrWhiteSpace($outputText)) {
        Write-Host $outputText
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
    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    Write-AzCliOutput -Output $output

    if ($exitCode -ne 0) {
        throw (New-AzCliFailureMessage -Description $Description -ExitCode $exitCode -Output $output)
    }
}

function Test-DnsForwardingRulesetVirtualNetworkLinkCircuitBreakerFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    return ($Message -match 'Operation has exceeded maximum processing count') -and
        ($Message -match 'virtualNetworkLinkResourceId=' -or $Message -match 'dnsForwardingRulesets/.*/virtualNetworkLinks')
}

function Reset-DnsForwardingRulesetVirtualNetworkLink {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$RulesetName,

        [Parameter(Mandatory = $true)]
        [string]$LinkName,

        [Parameter(Mandatory = $true)]
        [string]$ApiVersion
    )

    $linkResourceId = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Network/dnsForwardingRulesets/{2}/virtualNetworkLinks/{3}' -f $SubscriptionId, $ResourceGroupName, $RulesetName, $LinkName

    Write-Warning "Azure DNS Private Resolver reported a circuit-breaker failure for '$linkResourceId'. Resetting that ruleset VNet link before retrying deployment."

    $showOutput = & az resource show `
        --ids $linkResourceId `
        --api-version $ApiVersion `
        --only-show-errors `
        --output none 2>&1
    $showExitCode = $LASTEXITCODE

    if ($showExitCode -ne 0) {
        Write-Host "Ruleset VNet link '$linkResourceId' was not found or is no longer readable. Continuing with deployment retry."
        Write-AzCliOutput -Output $showOutput
        return
    }

    Invoke-AzDeploymentCommand `
        -Description "Deleting stale DNS forwarding ruleset VNet link '$LinkName'..." `
        -Arguments @('resource', 'delete', '--ids', $linkResourceId, '--api-version', $ApiVersion)

    Invoke-AzDeploymentCommand `
        -Description "Waiting for DNS forwarding ruleset VNet link '$LinkName' to be deleted..." `
        -Arguments @('resource', 'wait', '--deleted', '--ids', $linkResourceId, '--api-version', $ApiVersion, '--timeout', '600')
}

function Get-AvailableSubscriptionMessage {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Subscriptions
    )

    if ($Subscriptions.Count -eq 0) {
        return 'No subscriptions are visible to the current Azure CLI login.'
    }

    $Subscriptions |
        Sort-Object -Property name |
        ForEach-Object { '{0} ({1})' -f $_.name, $_.id } |
        Out-String
}

function Wait-OnPremDomainControllerReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$DomainName,

        [ValidateRange(1, 180)]
        [int]$TimeoutMinutes = 45
    )

    $deadline = (Get-Date).ToUniversalTime().AddMinutes($TimeoutMinutes)
    $attempt = 1
    $verificationScript = @'
param([string]$ExpectedDomainName)

$ErrorActionPreference = 'Stop'
$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem

if (($computerSystem.DomainRole -lt 4) -or ($computerSystem.Domain -ine $ExpectedDomainName)) {
    throw "VM is not yet a domain controller for $ExpectedDomainName. Current domain role: $($computerSystem.DomainRole); current domain: $($computerSystem.Domain)."
}

Import-Module ActiveDirectory -ErrorAction Stop
$domain = Get-ADDomain -ErrorAction Stop

if ($domain.DNSRoot -ine $ExpectedDomainName) {
    throw "Active Directory domain '$($domain.DNSRoot)' does not match expected domain '$ExpectedDomainName'."
}

Write-Output "AD_READY:$($domain.DNSRoot):$env:COMPUTERNAME"
'@

    while ($true) {
        Write-Host "Checking Active Directory forest readiness on '$VmName' (attempt $attempt)..."
        $output = & az vm run-command invoke `
            --resource-group $ResourceGroupName `
            --name $VmName `
            --command-id RunPowerShellScript `
            --scripts $verificationScript `
            --parameters "ExpectedDomainName=$DomainName" `
            --query 'value[0].message' `
            --output tsv `
            --only-show-errors 2>&1
        $exitCode = $LASTEXITCODE

        $outputText = ConvertTo-AzCliOutputText -Output $output
        if (($exitCode -eq 0) -and ($outputText -match 'AD_READY:')) {
            Write-AzCliOutput -Output $output
            return
        }

        $remainingSeconds = [int][Math]::Ceiling(($deadline - (Get-Date).ToUniversalTime()).TotalSeconds)
        if ($remainingSeconds -le 0) {
            throw "Active Directory forest '$DomainName' did not become ready on VM '$VmName' within $TimeoutMinutes minutes. Last Azure Run Command output: $outputText"
        }

        Write-Host "Active Directory forest is not ready yet. Waiting 30 seconds before retry $($attempt + 1)..."
        Start-Sleep -Seconds 30
        $attempt++
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found. Install Azure CLI before running this script.'
}

if (-not (Test-Path -Path $TemplateFile -PathType Leaf)) {
    throw "Template file not found: $TemplateFile"
}

$currentAccountJson = & az account show --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'Azure CLI is not signed in. Run az login, then rerun this script.'
}

$currentAccount = ($currentAccountJson | Out-String) | ConvertFrom-Json

if ($SubscriptionId) {
    $subscriptionsJson = & az account list --all --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to list Azure subscriptions for the current Azure CLI login.'
    }

    $subscriptions = @(($subscriptionsJson | Out-String) | ConvertFrom-Json)
    $selectedSubscription = @($subscriptions | Where-Object { $_.id -eq $SubscriptionId -or $_.name -eq $SubscriptionId })

    if ($selectedSubscription.Count -eq 0) {
        $availableSubscriptions = Get-AvailableSubscriptionMessage -Subscriptions $subscriptions
        throw "Subscription '$SubscriptionId' is not available in AzureCloud for the current Azure CLI login. Current subscription is '$($currentAccount.name)' ($($currentAccount.id)). Available subscriptions: $availableSubscriptions"
    }

    Invoke-AzDeploymentCommand `
        -Description "Selecting subscription $SubscriptionId..." `
        -Arguments @('account', 'set', '--subscription', $SubscriptionId)
}
else {
    Write-Host "Using current Azure CLI subscription '$($currentAccount.name)' ($($currentAccount.id))."
}

$null = & az account show --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to read the active Azure CLI subscription after subscription selection.'
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
            onPremResourceGroupName = @{ value = $OnPremResourceGroupName }
            azureResourceGroupName = @{ value = $AzureResourceGroupName }
            adminUsername = @{ value = $AdminUsername }
            vmSize = @{ value = $VmSize }
            adminPassword = @{ value = (ConvertTo-PlainText -SecureValue $AdminPassword) }
            domainSafeModeAdminPassword = @{ value = (ConvertTo-PlainText -SecureValue $DomainSafeModeAdminPassword) }
            vpnSharedKey = @{ value = (ConvertTo-PlainText -SecureValue $VpnSharedKey) }
            privateDnsZoneName = @{ value = $PrivateDnsZoneName }
            activeDirectoryDomainName = @{ value = $ActiveDirectoryDomainName }
            activeDirectoryNetbiosName = @{ value = $ActiveDirectoryNetbiosName }
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

    try {
        Invoke-AzDeploymentCommand `
            -Description "Starting subscription deployment '$DeploymentName' in $Location..." `
            -Arguments (@('deployment', 'sub', 'create') + $commonArguments)
    }
    catch {
        if (-not (Test-DnsForwardingRulesetVirtualNetworkLinkCircuitBreakerFailure -Message $_.Exception.Message)) {
            throw
        }

        $activeSubscriptionId = (& az account show --query id --output tsv --only-show-errors 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($activeSubscriptionId)) {
            throw "Deployment failed with a DNS forwarding ruleset VNet link circuit-breaker error, and the active subscription ID could not be read for automatic recovery. Original error: $($_.Exception.Message)"
        }

        Reset-DnsForwardingRulesetVirtualNetworkLink `
            -SubscriptionId $activeSubscriptionId `
            -ResourceGroupName $AzureResourceGroupName `
            -RulesetName $dnsForwardingRulesetName `
            -LinkName $dnsForwardingRulesetVirtualNetworkLinkName `
            -ApiVersion $dnsForwardingRulesetApiVersion

        Invoke-AzDeploymentCommand `
            -Description "Retrying subscription deployment '$DeploymentName' after resetting the DNS forwarding ruleset VNet link..." `
            -Arguments (@('deployment', 'sub', 'create') + $commonArguments)
    }

    Wait-OnPremDomainControllerReady `
        -ResourceGroupName $OnPremResourceGroupName `
        -VmName 'vm-onprem01' `
        -DomainName $ActiveDirectoryDomainName
}
finally {
    if (Test-Path -Path $tempParametersFile -PathType Leaf) {
        Remove-Item -Path $tempParametersFile -Force
    }
}
