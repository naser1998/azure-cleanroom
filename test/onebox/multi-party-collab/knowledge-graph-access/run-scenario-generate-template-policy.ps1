[CmdletBinding()]
param
(
    [string]
    $outDir = "$PSScriptRoot/generated",

    [Parameter(Mandatory)]
    [string]
    $ccfEndpoint,

    [string]
    $ccfOutDir = "",

    [string]
    $datastoreOutdir = "",

    [string]
    $contractId = "collab1-kg",

    [ValidateSet('mcr', 'local', 'acr')]
    [string]$registry = "local",

    [string]$repo = "localhost:5000",

    [string]$tag = "latest"
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$root = git rev-parse --show-toplevel
if ($ccfOutDir -eq "") {
    $ccfOutDir = "$outDir/ccf"
}

if ($datastoreOutdir -eq "") {
    $datastoreOutdir = "$outDir/datastores"
}

$serviceCert = $ccfOutDir + "/service_cert.pem"
if (-not (Test-Path -Path $serviceCert)) {
    throw "serviceCert at $serviceCert does not exist."
}

mkdir -p "$outDir/configurations"
$kgConfig = "$outDir/configurations/knowledge-graph-config"
$kgDatastoreConfig = "$datastoreOutdir/knowledge-graph-datastore-config"

mkdir -p "$datastoreOutdir/secrets"
$kgSecretStoreConfig = "$datastoreOutdir/secrets/knowledge-graph-secretstore-config"
$kgLocalSecretStore = "$datastoreOutdir/secrets/knowledge-graph-secretstore-local"

$resourceGroupTags = ""
if ($env:GITHUB_ACTIONS -eq "true") {
    $resourceGroup = "cl-ob-kg-${env:JOB_ID}-${env:RUN_ID}"
    $resourceGroupTags = "github_actions=multi-party-collab-${env:JOB_ID}-${env:RUN_ID}"
}
else {
    $user = $env:CODESPACES -eq "true" ? $env:GITHUB_USER : $env:USER
    $resourceGroup = "cl-ob-kg-${user}"
}

$tenantId = az account show --query "tenantId" --output tsv
$proposalId = (az cleanroom governance member set-tenant-id `
        --identifier kg `
        --tenant-id $tenantId `
        --query "proposalId" `
        --output tsv `
        --governance-client "ob-kg-client")

az cleanroom governance proposal vote `
    --proposal-id $proposalId `
    --action accept `
    --governance-client "ob-kg-client"

az cleanroom secretstore add `
    --name kg-local-store `
    --config $kgSecretStoreConfig `
    --backingstore-type Local_File `
    --backingstore-path $kgLocalSecretStore

pwsh $PSScriptRoot/../prepare-resources.ps1 `
    -resourceGroup $resourceGroup `
    -resourceGroupTags $resourceGroupTags `
    -kvType akvpremium `
    -outDir $outDir

$result = Get-Content "$outDir/$resourceGroup/resources.generated.json" | ConvertFrom-Json

az cleanroom config init --cleanroom-config $kgConfig
$identity = $(az resource show --ids $result.mi.id --query "properties") | ConvertFrom-Json

az cleanroom config add-identity az-federated `
    --cleanroom-config $kgConfig `
    -n kg-identity `
    --client-id $identity.clientId `
    --tenant-id $identity.tenantId `
    --backing-identity cleanroom_cgs_oidc

az cleanroom secretstore add `
    --name kg-dek-store `
    --config $kgSecretStoreConfig `
    --backingstore-type Azure_KeyVault `
    --backingstore-id $result.dek.kv.id 

az cleanroom secretstore add `
    --name kg-kek-store `
    --config $kgSecretStoreConfig `
    --backingstore-type Azure_KeyVault_Managed_HSM `
    --backingstore-id $result.kek.kv.id `
    --attestation-endpoint $result.maa_endpoint

$containerSuffix = $($($(New-Guid).Guid) -replace '-').ToLower()
az cleanroom config set-logging `
    --cleanroom-config $kgConfig `
    --storage-account $result.sa.id `
    --identity kg-identity `
    --datastore-config $kgDatastoreConfig `
    --secretstore-config $kgSecretStoreConfig `
    --datastore-secret-store kg-local-store `
    --dek-secret-store kg-dek-store `
    --kek-secret-store kg-kek-store `
    --encryption-mode CPK `
    --container-suffix $containerSuffix

$containerSuffix = $($($(New-Guid).Guid) -replace '-').ToLower()
az cleanroom config set-telemetry `
    --cleanroom-config $kgConfig `
    --storage-account $result.sa.id `
    --identity kg-identity `
    --datastore-config $kgDatastoreConfig `
    --secretstore-config $kgSecretStoreConfig `
    --datastore-secret-store kg-local-store `
    --dek-secret-store kg-dek-store `
    --kek-secret-store kg-kek-store `
    --encryption-mode CPK `
    --container-suffix $containerSuffix

pwsh $PSScriptRoot/build-application.ps1 -tag $tag -repo $repo -push

. $PSScriptRoot/../helpers.ps1
$imageDigest = Get-Digest -repo $repo -containerName knowledge-graph-access -tag $tag

az cleanroom config add-application `
    --cleanroom-config $kgConfig `
    --name knowledge-graph `
    --image "$repo/knowledge-graph-access@$imageDigest" `
    --command "python /app/app.py" `
    --ports 8200 `
    --cpu 0.5 `
    --memory 4 `
    --auto-start

az cleanroom config network http enable `
    --cleanroom-config $kgConfig `
    --direction inbound

az cleanroom config view `
    --cleanroom-config $kgConfig `
    --output-file $outDir/configurations/cleanroom-config

az cleanroom config validate --cleanroom-config $outDir/configurations/cleanroom-config

$data = Get-Content -Raw $outDir/configurations/cleanroom-config
az cleanroom governance contract create `
    --data "$data" `
    --id $contractId `
    --governance-client "ob-kg-client"

$version = (az cleanroom governance contract show `
        --id $contractId `
        --query "version" `
        --output tsv `
        --governance-client "ob-kg-client")

az cleanroom governance contract propose `
    --version $version `
    --id $contractId `
    --governance-client "ob-kg-client"

$contract = (az cleanroom governance contract show `
        --id $contractId `
        --governance-client "ob-kg-client" | ConvertFrom-Json)

az cleanroom governance contract vote `
    --id $contractId `
    --proposal-id $contract.proposalId `
    --action accept `
    --governance-client "ob-kg-client"

mkdir -p $outDir/deployments
if ($registry -ne "mcr") {
    $env:AZCLI_CLEANROOM_CONTAINER_REGISTRY_URL = $repo
    $env:AZCLI_CLEANROOM_SIDECARS_VERSIONS_DOCUMENT_URL = "${repo}/sidecar-digests:$tag"
}

az cleanroom governance deployment generate `
    --contract-id $contractId `
    --governance-client "ob-kg-client" `
    --output-dir $outDir/deployments `
    --security-policy-creation-option allow-all

az cleanroom governance deployment template propose `
    --template-file $outDir/deployments/cleanroom-arm-template.json `
    --contract-id $contractId `
    --governance-client "ob-kg-client"

az cleanroom governance deployment policy propose `
    --policy-file $outDir/deployments/cleanroom-governance-policy.json `
    --contract-id $contractId `
    --governance-client "ob-kg-client"

az cleanroom governance contract runtime-option propose `
    --option logging `
    --action enable `
    --contract-id $contractId `
    --governance-client "ob-kg-client"

az cleanroom governance contract runtime-option propose `
    --option telemetry `
    --action enable `
    --contract-id $contractId `
    --governance-client "ob-kg-client"

az cleanroom governance ca propose-enable `
    --contract-id $contractId `
    --governance-client "ob-kg-client"

$clientName = "ob-kg-client"
pwsh $PSScriptRoot/../verify-deployment-proposals.ps1 `
    -cleanroomConfig $kgConfig `
    -governanceClient $clientName

$proposalId = az cleanroom governance deployment template show `
    --contract-id $contractId `
    --governance-client $clientName `
    --query "proposalIds[0]" `
    --output tsv
az cleanroom governance proposal vote `
    --proposal-id $proposalId `
    --action accept `
    --governance-client $clientName

$proposalId = az cleanroom governance deployment policy show `
    --contract-id $contractId `
    --governance-client $clientName `
    --query "proposalIds[0]" `
    --output tsv
az cleanroom governance proposal vote `
    --proposal-id $proposalId `
    --action accept `
    --governance-client $clientName

$proposalId = az cleanroom governance contract runtime-option get `
    --option logging `
    --contract-id $contractId `
    --governance-client $clientName `
    --query "proposalIds[0]" `
    --output tsv
az cleanroom governance proposal vote `
    --proposal-id $proposalId `
    --action accept `
    --governance-client $clientName

$proposalId = az cleanroom governance contract runtime-option get `
    --option telemetry `
    --contract-id $contractId `
    --governance-client $clientName `
    --query "proposalIds[0]" `
    --output tsv
az cleanroom governance proposal vote `
    --proposal-id $proposalId `
    --action accept `
    --governance-client $clientName

$proposalId = az cleanroom governance ca show `
    --contract-id $contractId `
    --governance-client $clientName `
    --query "proposalIds[0]" `
    --output tsv
az cleanroom governance proposal vote `
    --proposal-id $proposalId `
    --action accept `
    --governance-client $clientName

az cleanroom governance ca generate-key `
    --contract-id $contractId `
    --governance-client $clientName

az cleanroom governance ca show `
    --contract-id $contractId `
    --governance-client $clientName `
    --query "caCert" `
    --output tsv > $outDir/cleanroomca.crt

az cleanroom config wrap-deks `
    --contract-id $contractId `
    --cleanroom-config $kgConfig `
    --datastore-config $kgDatastoreConfig `
    --secretstore-config $kgSecretStoreConfig `
    --key-release-mode allow-all `
    --governance-client "ob-kg-client"

pwsh $PSScriptRoot/../setup-oidc-issuer.ps1 `
    -resourceGroup $resourceGroup `
    -outDir $outDir `
    -governanceClient "ob-kg-client"
$issuerUrl = Get-Content $outDir/$resourceGroup/issuer-url.txt

pwsh $PSScriptRoot/../setup-access.ps1 `
    -resourceGroup $resourceGroup `
    -subject $contractId `
    -issuerUrl $issuerUrl `
    -outDir $outDir `
    -kvType akvpremium `
    -governanceClient "ob-kg-client"
