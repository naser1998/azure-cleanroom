[CmdletBinding()]
param
(
    [switch]
    $NoBuild,

    [ValidateSet('mcr', 'local', 'acr')]
    [string]$registry = "local",

    [string]$repo = "localhost:5000",

    [string]$tag = "latest"
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$outDir = "$PSScriptRoot/generated"
rm -rf $outDir
Write-Host "Using $registry registry for cleanroom container images."
$datastoreOutdir = "$outDir/datastores"

$root = git rev-parse --show-toplevel
pwsh $root/test/onebox/multi-party-collab/deploy-virtual-cleanroom-governance.ps1 `
    -NoBuild:$NoBuild `
    -registry $registry `
    -repo $repo `
    -tag $tag `
    -ccfProjectName "ob-ccf-kg-access" `
    -projectName "ob-kg-client" `
    -initialMemberName "kg" `
    -outDir $outDir
$ccfEndpoint = $(Get-Content $outDir/ccf/ccf.json | ConvertFrom-Json).endpoint

$contractId = "collab1-kg"
pwsh $PSScriptRoot/run-scenario-generate-template-policy.ps1 `
    -registry $registry `
    -repo $repo `
    -tag $tag `
    -outDir $outDir `
    -ccfEndpoint $ccfEndpoint `
    -datastoreOutDir $datastoreOutdir `
    -contractId $contractId

$registry_local_endpoint = ""
if ($registry -eq "local") {
    $registry_local_endpoint = "ccr-registry:5000"
}

pwsh $root/test/onebox/multi-party-collab/convert-template.ps1 -outDir $outDir -registry_local_endpoint $registry_local_endpoint -repo $repo -tag $tag
pwsh $root/test/onebox/multi-party-collab/deploy-virtual-cleanroom.ps1 -outDir $outDir -repo $repo -tag $tag

Get-Job -Command "*kubectl port-forward ccr-client-proxy*" | Stop-Job
Get-Job -Command "*kubectl port-forward ccr-client-proxy*" | Remove-Job
kubectl port-forward ccr-client-proxy 10081:10080 &

bash $root/src/scripts/wait-for-it.sh --timeout=20 --strict 127.0.0.1:10081 -- echo "ccr-client-proxy is available"

$timeout = New-TimeSpan -Minutes 5
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
while ((curl -o /dev/null -w "%{http_code}" -s http://ccr.cleanroom.local:8200/health --proxy http://127.0.0.1:10081) -ne "200") {
    Write-Host "Waiting for knowledge graph app endpoint to be up at http://ccr.cleanroom.local:8200/health"
    Start-Sleep -Seconds 3
    if ($stopwatch.elapsed -gt $timeout) {
        throw "Hit timeout waiting for knowledge graph app endpoint to be up."
    }
}

Write-Host "Company A graph:"
curl -s http://ccr.cleanroom.local:8200/graph?company=company-a --proxy http://127.0.0.1:10081 | jq '.viewer, (.nodes | length), (.edges | length)'

Write-Host "Company B graph:"
curl -s http://ccr.cleanroom.local:8200/graph?company=company-b --proxy http://127.0.0.1:10081 | jq '.viewer, (.nodes | length), (.edges | length)'

Write-Host "Visual compare page available through proxy at:"
Write-Host "  http://ccr.cleanroom.local:8200/compare (use --proxy http://127.0.0.1:10081)"
Write-Host "Tip: in another shell run: curl -s http://ccr.cleanroom.local:8200/compare --proxy http://127.0.0.1:10081 > /tmp/kg-compare.html"

Start-Sleep -Seconds 5
Write-Host "Exporting logs..."
$response = curl -X POST -s http://ccr.cleanroom.local:8200/gov/exportLogs --proxy http://127.0.0.1:10081
$expectedResponse = '{"message":"Application telemetry data exported successfully."}'
if ($response -ne $expectedResponse) {
    Write-Host -ForegroundColor Red "Did not get expected response. Received: $response."
    exit 1
}

Write-Host "Exporting telemetry..."
$response = curl -X POST -s http://ccr.cleanroom.local:8200/gov/exportTelemetry --proxy http://127.0.0.1:10081
$expectedResponse = '{"message":"Infrastructure telemetry data exported successfully."}'
if ($response -ne $expectedResponse) {
    Write-Host -ForegroundColor Red "Did not get expected response. Received: $response."
    exit 1
}

mkdir -p $outDir/results
az cleanroom telemetry download `
    --cleanroom-config $outDir/configurations/knowledge-graph-config `
    --datastore-config $datastoreOutdir/knowledge-graph-datastore-config `
    --target-folder $outDir/results

az cleanroom logs download `
    --cleanroom-config $outDir/configurations/knowledge-graph-config `
    --datastore-config $datastoreOutdir/knowledge-graph-datastore-config `
    --target-folder $outDir/results

Write-Host "Scenario completed. Use the proxy to view:"
Write-Host "  /company-a (on port 8200)"
Write-Host "  /company-b (on port 8200)"
Write-Host "  /compare (on port 8200)"
