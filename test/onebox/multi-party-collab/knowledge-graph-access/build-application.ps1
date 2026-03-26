param(
    [parameter(Mandatory = $false)]
    [string]$tag = "latest",

    [parameter(Mandatory = $false)]
    [string]$repo = "docker.io",

    [parameter(Mandatory = $false)]
    [switch]$push
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

if ($repo) {
    $imageName = "$repo/knowledge-graph-access:$tag"
}
else {
    $imageName = "knowledge-graph-access:$tag"
}

docker image build -t $imageName `
    -f $PSScriptRoot/app/Dockerfile.app $PSScriptRoot/app
if ($push) {
    docker push $imageName
}
