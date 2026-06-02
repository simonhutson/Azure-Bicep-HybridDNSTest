[CmdletBinding()]
param(
    [string]$Location = 'swedencentral',
    [string]$DeploymentName = ('hybrid-dns-{0:yyyyMMdd-HHmmss}' -f (Get-Date)),
    [string]$TemplateFile = (Join-Path $PSScriptRoot 'main.bicep'),
    [string]$OnPremResourceGroupName = 'rg-onprem',
    [string]$AzureResourceGroupName = 'rg-azure',
    [string]$VmApplicationGalleryName = 'galHybridDns',
    [string]$VmApplicationPackageStorageAccountName = '',
    [string]$VmApplicationPackageContainerName = 'vm-applications',
    [string]$UbuntuRouterVmApplicationVersion = '1.0.0',
    [string]$UbuntuRouterVmApplicationPackageUri = '',
    [string]$UbuntuRouterVmApplicationPackageSourcePath = (Join-Path $PSScriptRoot 'vm-applications\ubuntu-sdwan-router'),
    [ValidateRange(1, 168)]
    [int]$UbuntuRouterVmApplicationSasHours = 72,
    [ValidateRange(0, 1800)]
    [int]$VmApplicationStorageRolePropagationWaitSeconds = 300,
    [string]$AdminUsername = 'azureadmin',
    [string]$VmSize = 'Standard_D2ads_v5',
    [string]$PrivateDnsZoneName = 'contoso.azure',
    [ValidateLength(1, 15)]
    [string]$ActiveDirectoryNetbiosName = 'CONTOSO',
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [securestring]$AdminPassword,
    [securestring]$DomainSafeModeAdminPassword,
    [securestring]$VpnSharedKey,
    [switch]$SkipVmApplicationStorageRoleAssignment,
    [switch]$ValidateOnly,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$deployScriptVersion = '2026-06-02.2'

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

function ConvertFrom-Base64UrlString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $base64 = $Value.Replace('-', '+').Replace('_', '/')
    switch ($base64.Length % 4) {
        0 { break }
        2 { $base64 += '==' }
        3 { $base64 += '=' }
        default { throw 'Invalid base64url value.' }
    }

    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($base64))
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
    if (-not $ReturnOutput) {
        Write-AzCliOutput -Output $output
    }

    if ($exitCode -ne 0) {
        throw (New-AzCliFailureMessage -Description $Description -ExitCode $exitCode -Output $output)
    }

    if ($ReturnOutput) {
        return ConvertTo-AzCliOutputText -Output $output
    }
}

function Test-StorageDataPlaneAuthorizationFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    return $Message -match 'You do not have the required permissions needed to perform this operation|AuthorizationPermissionMismatch|This request is not authorized|Forbidden|\b403\b'
}

function Invoke-StorageDataPlaneCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Description,

        [Parameter(Mandatory = $true)]
        [string]$RoleScope,

        [Parameter(Mandatory = $true)]
        [int]$PropagationWaitSeconds,

        [switch]$ReturnOutput
    )

    $deadline = (Get-Date).ToUniversalTime().AddSeconds($PropagationWaitSeconds)
    $attempt = 1

    while ($true) {
        try {
            if ($ReturnOutput) {
                return Invoke-AzCliCommand -Arguments $Arguments -Description $Description -ReturnOutput
            }

            Invoke-AzCliCommand -Arguments $Arguments -Description $Description
            return
        }
        catch {
            $message = $_.Exception.Message
            if (-not (Test-StorageDataPlaneAuthorizationFailure -Message $message)) {
                throw
            }

            $remainingSeconds = [int][Math]::Ceiling(($deadline - (Get-Date).ToUniversalTime()).TotalSeconds)
            if ($remainingSeconds -le 0) {
                throw "Storage data-plane authorization did not become available within $PropagationWaitSeconds seconds for scope '$RoleScope'. Storage Blob Data Contributor may still be propagating, or the active principal may need that role at the storage account scope. Rerun the script after a few minutes. Original error: $message"
            }

            $sleepSeconds = [Math]::Min(15, $remainingSeconds)
            Write-Host "Storage data-plane authorization is not available yet. Waiting $sleepSeconds seconds before retry $($attempt + 1)..."
            Start-Sleep -Seconds $sleepSeconds
            $attempt++
        }
    }
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

function Get-DefaultVmApplicationStorageAccountName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName
    )

    $hashInput = '{0}/{1}/ubuntu-sdwan-router' -f $CurrentSubscriptionId, $ResourceGroupName.ToLowerInvariant()
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($hashInput))
    }
    finally {
        $sha256.Dispose()
    }

    $hashText = -join ($hashBytes[0..7] | ForEach-Object { $_.ToString('x2') })
    return ('stvmapp{0}' -f $hashText)
}

function Get-AzureCliPrincipalInfo {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Account
    )

    $accountUserType = $Account.user.type
    $principalType = if ($accountUserType -eq 'user') { 'User' } else { 'ServicePrincipal' }

    $accessToken = Invoke-AzCliCommand `
        -Description 'Resolving active Azure CLI principal from the current access token...' `
        -Arguments @('account', 'get-access-token', '--resource', 'https://management.azure.com/', '--query', 'accessToken', '--output', 'tsv', '--only-show-errors') `
        -ReturnOutput

    $tokenSegments = $accessToken.Split('.')
    if ($tokenSegments.Count -lt 2) {
        throw 'Unable to resolve the active Azure CLI principal because the access token format was unexpected.'
    }

    $tokenPayload = ConvertFrom-Json -InputObject (ConvertFrom-Base64UrlString -Value $tokenSegments[1])
    if ([string]::IsNullOrWhiteSpace($tokenPayload.oid)) {
        throw 'Unable to resolve the active Azure CLI principal because the access token did not contain an oid claim.'
    }

    return [pscustomobject]@{
        ObjectId = $tokenPayload.oid
        PrincipalType = $principalType
    }
}

function Ensure-StorageBlobDataContributorAssignment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Scope,

        [Parameter(Mandatory = $true)]
        [string]$PrincipalObjectId,

        [Parameter(Mandatory = $true)]
        [string]$PrincipalType
    )

    $assignmentJson = Invoke-AzCliCommand `
        -Description 'Checking VM Application package storage data-plane role assignment...' `
        -Arguments @(
            'role', 'assignment', 'list',
            '--assignee', $PrincipalObjectId,
            '--scope', $Scope,
            '--role', 'Storage Blob Data Contributor',
            '--include-inherited',
            '--output', 'json',
            '--only-show-errors'
        ) `
        -ReturnOutput

    $assignments = @()
    if (-not [string]::IsNullOrWhiteSpace($assignmentJson)) {
        $parsedAssignments = ConvertFrom-Json -InputObject $assignmentJson
        if ($null -ne $parsedAssignments) {
            $assignments = @($parsedAssignments)
        }
    }

    if ($assignments.Count -gt 0) {
        Write-Host 'Storage Blob Data Contributor is already assigned for VM Application package storage.'
        return
    }

    try {
        Invoke-AzCliCommand `
            -Description 'Assigning Storage Blob Data Contributor for VM Application package storage...' `
            -Arguments @(
                'role', 'assignment', 'create',
                '--assignee-object-id', $PrincipalObjectId,
                '--assignee-principal-type', $PrincipalType,
                '--role', 'Storage Blob Data Contributor',
                '--scope', $Scope,
                '--only-show-errors',
                '--output', 'none'
            )
    }
    catch {
        throw "Unable to assign Storage Blob Data Contributor on '$Scope' to the active Azure CLI principal. Assign that role manually, wait for RBAC propagation, then rerun the script. Original error: $($_.Exception.Message)"
    }

    Write-Host 'Storage Blob Data Contributor role assignment created. If the next storage operation fails, wait a few minutes for RBAC propagation and rerun the script.'
}

function New-UbuntuRouterVmApplicationPackageUri {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Location,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$StorageAccountName,

        [Parameter(Mandatory = $true)]
        [string]$ContainerName,

        [Parameter(Mandatory = $true)]
        [string]$PackageSourcePath,

        [Parameter(Mandatory = $true)]
        [string]$ApplicationVersion,

        [Parameter(Mandatory = $true)]
        [int]$SasHours,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AzureCliPrincipal,

        [Parameter(Mandatory = $true)]
        [bool]$AssignStorageRole,

        [Parameter(Mandatory = $true)]
        [int]$StorageRolePropagationWaitSeconds
    )

    if (-not (Test-Path -Path $PackageSourcePath -PathType Container)) {
        throw "Ubuntu router VM Application package source folder not found: $PackageSourcePath"
    }

    if ($StorageAccountName -notmatch '^[a-z0-9]{3,24}$') {
        throw "Storage account name '$StorageAccountName' is invalid. Use 3-24 lowercase letters and numbers."
    }

    if ($ContainerName -notmatch '^[a-z0-9](?!.*--)[a-z0-9-]{1,61}[a-z0-9]$') {
        throw "Storage container name '$ContainerName' is invalid. Use a valid lowercase Azure blob container name."
    }

    $tempArchivePath = Join-Path ([IO.Path]::GetTempPath()) ('ubuntu-sdwan-router-{0}-{1}.zip' -f $ApplicationVersion, ([Guid]::NewGuid()))
    $blobName = 'ubuntu-sdwan-router/{0}/ubuntu-sdwan-router-{0}.zip' -f $ApplicationVersion

    try {
        Write-Host "Packaging Ubuntu SD-WAN/router VM Application from '$PackageSourcePath'..."
        Compress-Archive -Path (Join-Path $PackageSourcePath '*') -DestinationPath $tempArchivePath -Force

        Invoke-AzCliCommand `
            -Description "Ensuring resource group '$ResourceGroupName' exists for VM Application package storage..." `
            -Arguments @(
                'group', 'create',
                '--name', $ResourceGroupName,
                '--location', $Location,
                '--tags', 'workload=hybrid-dns-test', 'environment=lab',
                '--only-show-errors',
                '--output', 'none'
            )

        & az storage account show `
            --resource-group $ResourceGroupName `
            --name $StorageAccountName `
            --only-show-errors `
            --output none 2>$null

        if ($LASTEXITCODE -ne 0) {
            Invoke-AzCliCommand `
                -Description "Creating storage account '$StorageAccountName' for VM Application packages..." `
                -Arguments @(
                    'storage', 'account', 'create',
                    '--resource-group', $ResourceGroupName,
                    '--name', $StorageAccountName,
                    '--location', $Location,
                    '--kind', 'StorageV2',
                    '--sku', 'Standard_LRS',
                    '--https-only', 'true',
                    '--min-tls-version', 'TLS1_2',
                    '--allow-blob-public-access', 'false',
                    '--public-network-access', 'Enabled',
                    '--tags', 'workload=hybrid-dns-test', 'environment=lab',
                    '--only-show-errors',
                    '--output', 'none'
                )
        }
        else {
            Write-Host "Using existing storage account '$StorageAccountName'."
        }

        $storageAccountResourceId = Invoke-AzCliCommand `
            -Description "Resolving storage account resource ID for VM Application package storage..." `
            -Arguments @(
                'storage', 'account', 'show',
                '--resource-group', $ResourceGroupName,
                '--name', $StorageAccountName,
                '--query', 'id',
                '--only-show-errors',
                '--output', 'tsv'
            ) `
            -ReturnOutput

        if ($AssignStorageRole) {
            Ensure-StorageBlobDataContributorAssignment `
                -Scope $storageAccountResourceId `
                -PrincipalObjectId $AzureCliPrincipal.ObjectId `
                -PrincipalType $AzureCliPrincipal.PrincipalType
        }
        else {
            Write-Host 'Skipping automatic Storage Blob Data Contributor role assignment for VM Application package storage.'
        }

        $blobEndpoint = Invoke-AzCliCommand `
            -Description "Resolving storage account blob endpoint..." `
            -Arguments @(
                'storage', 'account', 'show',
                '--resource-group', $ResourceGroupName,
                '--name', $StorageAccountName,
                '--query', 'primaryEndpoints.blob',
                '--only-show-errors',
                '--output', 'tsv'
            ) `
            -ReturnOutput

        Invoke-StorageDataPlaneCommand `
            -Description "Ensuring blob container '$ContainerName' exists for VM Application packages using Microsoft Entra authentication..." `
            -Arguments @(
                'storage', 'container', 'create',
                '--account-name', $StorageAccountName,
                '--name', $ContainerName,
                '--public-access', 'off',
                '--auth-mode', 'login',
                '--only-show-errors',
                '--output', 'none'
            ) `
            -RoleScope $storageAccountResourceId `
            -PropagationWaitSeconds $StorageRolePropagationWaitSeconds

        Invoke-StorageDataPlaneCommand `
            -Description "Uploading Ubuntu SD-WAN/router VM Application package to '$ContainerName/$blobName' using Microsoft Entra authentication..." `
            -Arguments @(
                'storage', 'blob', 'upload',
                '--account-name', $StorageAccountName,
                '--container-name', $ContainerName,
                '--name', $blobName,
                '--file', $tempArchivePath,
                '--overwrite', 'true',
                '--content-type', 'application/zip',
                '--auth-mode', 'login',
                '--only-show-errors',
                '--output', 'none'
            ) `
            -RoleScope $storageAccountResourceId `
            -PropagationWaitSeconds $StorageRolePropagationWaitSeconds

        $sasExpiryUtc = (Get-Date).ToUniversalTime().AddHours($SasHours).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $sasToken = Invoke-StorageDataPlaneCommand `
            -Description "Generating read-only user delegation SAS URI for Azure Compute Gallery package import..." `
            -Arguments @(
                'storage', 'blob', 'generate-sas',
                '--account-name', $StorageAccountName,
                '--container-name', $ContainerName,
                '--name', $blobName,
                '--permissions', 'r',
                '--expiry', $sasExpiryUtc,
                '--https-only',
                '--as-user',
                '--auth-mode', 'login',
                '--only-show-errors',
                '--output', 'tsv'
            ) `
            -RoleScope $storageAccountResourceId `
            -PropagationWaitSeconds $StorageRolePropagationWaitSeconds `
            -ReturnOutput

        return ('{0}{1}/{2}?{3}' -f $blobEndpoint, $ContainerName, $blobName, $sasToken)
    }
    finally {
        if (Test-Path -Path $tempArchivePath -PathType Leaf) {
            Remove-Item -Path $tempArchivePath -Force
        }
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

$activeAccountJson = & az account show --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to read the active Azure CLI subscription after subscription selection.'
}

$activeAccount = ($activeAccountJson | Out-String) | ConvertFrom-Json
$azureCliPrincipal = Get-AzureCliPrincipalInfo -Account $activeAccount

if (-not $AdminPassword) {
    $AdminPassword = Read-Host -Prompt 'VM administrator password' -AsSecureString
}

if (-not $DomainSafeModeAdminPassword) {
    $DomainSafeModeAdminPassword = Read-Host -Prompt 'Directory Services Restore Mode password' -AsSecureString
}

if (-not $VpnSharedKey) {
    $VpnSharedKey = Read-Host -Prompt 'VPN shared key' -AsSecureString
}

if (-not $UbuntuRouterVmApplicationPackageUri) {
    if ($ValidateOnly -or $WhatIf) {
        Write-Host 'Skipping automatic Ubuntu router VM Application package upload for validation/what-if. Pass -UbuntuRouterVmApplicationPackageUri to include an application version in this preview.'
    }
    else {
        if (-not $VmApplicationPackageStorageAccountName) {
            $VmApplicationPackageStorageAccountName = Get-DefaultVmApplicationStorageAccountName `
                -CurrentSubscriptionId $activeAccount.id `
                -ResourceGroupName $AzureResourceGroupName
        }

        $UbuntuRouterVmApplicationPackageUri = New-UbuntuRouterVmApplicationPackageUri `
            -Location $Location `
            -ResourceGroupName $AzureResourceGroupName `
            -StorageAccountName $VmApplicationPackageStorageAccountName `
            -ContainerName $VmApplicationPackageContainerName `
            -PackageSourcePath $UbuntuRouterVmApplicationPackageSourcePath `
            -ApplicationVersion $UbuntuRouterVmApplicationVersion `
            -SasHours $UbuntuRouterVmApplicationSasHours `
            -AzureCliPrincipal $azureCliPrincipal `
            -AssignStorageRole (-not $SkipVmApplicationStorageRoleAssignment) `
            -StorageRolePropagationWaitSeconds $VmApplicationStorageRolePropagationWaitSeconds
    }
}
else {
    Write-Host 'Using provided Ubuntu router VM Application package URI.'
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
            vmApplicationGalleryName = @{ value = $VmApplicationGalleryName }
            ubuntuRouterVmApplicationVersion = @{ value = $UbuntuRouterVmApplicationVersion }
            ubuntuRouterVmApplicationPackageUri = @{ value = $UbuntuRouterVmApplicationPackageUri }
            adminUsername = @{ value = $AdminUsername }
            vmSize = @{ value = $VmSize }
            adminPassword = @{ value = (ConvertTo-PlainText -SecureValue $AdminPassword) }
            domainSafeModeAdminPassword = @{ value = (ConvertTo-PlainText -SecureValue $DomainSafeModeAdminPassword) }
            vpnSharedKey = @{ value = (ConvertTo-PlainText -SecureValue $VpnSharedKey) }
            privateDnsZoneName = @{ value = $PrivateDnsZoneName }
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

    Invoke-AzDeploymentCommand `
        -Description "Starting subscription deployment '$DeploymentName' in $Location..." `
        -Arguments (@('deployment', 'sub', 'create') + $commonArguments)
}
finally {
    if (Test-Path -Path $tempParametersFile -PathType Leaf) {
        Remove-Item -Path $tempParametersFile -Force
    }
}
