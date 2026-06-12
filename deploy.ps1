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
    [string]$DnsResolverInboundEndpointPrivateIpAddress = '172.16.5.4',
    [string]$ActiveDirectoryDomainName = 'contoso.onprem',
    [ValidateLength(1, 15)]
    [string]$ActiveDirectoryNetbiosName = 'CONTOSO',
    [ValidateRange(1, 180)]
    [int]$DomainControllerReadyTimeoutMinutes = 45,
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [securestring]$AdminPassword,
    [securestring]$DomainSafeModeAdminPassword,
    [securestring]$VpnSharedKey,
    [switch]$ValidateOnly,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$deployScriptVersion = '2026-06-12.2'
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

function ConvertTo-AzVmRunCommandMessageText {
    param(
        [AllowEmptyString()]
        [string]$OutputText
    )

    if ([string]::IsNullOrWhiteSpace($OutputText)) {
        return ''
    }

    try {
        $runCommandResult = $OutputText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $OutputText
    }

    $valueProperty = $runCommandResult.PSObject.Properties['value']
    if ($null -eq $valueProperty) {
        return $OutputText
    }

    $messages = @(
        foreach ($statusEntry in @($valueProperty.Value)) {
            $messageProperty = $statusEntry.PSObject.Properties['message']
            if ($null -ne $messageProperty -and -not [string]::IsNullOrWhiteSpace([string]$messageProperty.Value)) {
                ([string]$messageProperty.Value).Trim()
            }
        }
    )

    if ($messages.Count -eq 0) {
        return ''
    }

    return ($messages -join [Environment]::NewLine).Trim()
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
    $encodedExpectedDomainName = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($DomainName))
    $verificationScript = @'
$ErrorActionPreference = 'Stop'
$ExpectedDomainName = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('__EXPECTED_DOMAIN_NAME_BASE64__'))

function Write-AdReadinessResult {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Ready,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $status = if ($Ready) { 'AD_READY' } else { 'AD_NOT_READY' }
    [Console]::Out.WriteLine("$($status):$Message")
}

try {
$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem

if (($computerSystem.DomainRole -lt 4) -or ($computerSystem.Domain -ine $ExpectedDomainName)) {
    Write-AdReadinessResult -Ready $false -Message "VM is not yet a domain controller for $ExpectedDomainName. Current domain role: $($computerSystem.DomainRole); current domain: $($computerSystem.Domain)."
    exit 1
}

Import-Module ActiveDirectory -ErrorAction Stop
$domain = Get-ADDomain -ErrorAction Stop

if ($domain.DNSRoot -ine $ExpectedDomainName) {
    Write-AdReadinessResult -Ready $false -Message "Active Directory domain '$($domain.DNSRoot)' does not match expected domain '$ExpectedDomainName'."
    exit 1
}

Write-AdReadinessResult -Ready $true -Message "$($domain.DNSRoot):$env:COMPUTERNAME"
exit 0
}
catch {
    Write-AdReadinessResult -Ready $false -Message $_.Exception.Message
    exit 1
}
'@.Replace('__EXPECTED_DOMAIN_NAME_BASE64__', $encodedExpectedDomainName)

    while ($true) {
        Write-Host "Checking Active Directory forest readiness on '$VmName' (attempt $attempt)..."
        $output = & az vm run-command invoke `
            --resource-group $ResourceGroupName `
            --name $VmName `
            --command-id RunPowerShellScript `
            --scripts $verificationScript `
            --output json `
            --only-show-errors 2>&1
        $exitCode = $LASTEXITCODE

        $outputText = ConvertTo-AzCliOutputText -Output $output
        $messageText = ConvertTo-AzVmRunCommandMessageText -OutputText $outputText
        $lastRunCommandOutput = $messageText
        if ([string]::IsNullOrWhiteSpace($lastRunCommandOutput)) {
            $lastRunCommandOutput = $outputText
        }
        if ([string]::IsNullOrWhiteSpace($lastRunCommandOutput)) {
            $lastRunCommandOutput = "Azure CLI returned no Run Command output. Exit code: $exitCode."
        }

        if ($messageText -match '(?m)^AD_READY:') {
            Write-Host $messageText
            return
        }

        $remainingSeconds = [int][Math]::Ceiling(($deadline - (Get-Date).ToUniversalTime()).TotalSeconds)
        if ($remainingSeconds -le 0) {
            throw "Active Directory forest '$DomainName' did not become ready on VM '$VmName' within $TimeoutMinutes minutes. Last Azure Run Command output: $lastRunCommandOutput"
        }

        Write-Host "Active Directory forest is not ready yet. Last check: $lastRunCommandOutput"
        Write-Host "Waiting 30 seconds before retry $($attempt + 1)..."
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
            dnsResolverInboundEndpointPrivateIpAddress = @{ value = $DnsResolverInboundEndpointPrivateIpAddress }
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
        -DomainName $ActiveDirectoryDomainName `
        -TimeoutMinutes $DomainControllerReadyTimeoutMinutes
}
finally {
    if (Test-Path -Path $tempParametersFile -PathType Leaf) {
        Remove-Item -Path $tempParametersFile -Force
    }
}
