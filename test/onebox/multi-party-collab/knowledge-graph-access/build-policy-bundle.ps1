param(
    [parameter(Mandatory = $false)]
    [string]$tag = "latest",

    [parameter(Mandatory = $false)]
    [string]$repo = "localhost:5000"
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$root = git rev-parse --show-toplevel
$tmpDir = Join-Path $PSScriptRoot "generated/policy-bundle"
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

@'
package policy

default allow = false

allow if {
  input.method == "GET"
  input.path == "/"
}

allow if {
  input.method == "GET"
  input.path == "/health"
}

allow if {
  input.method == "GET"
  startswith(input.path, "/graph")
}

allow if {
  input.method == "GET"
  input.path == "/company-a"
}

allow if {
  input.method == "GET"
  input.path == "/company-b"
}

allow if {
  input.method == "GET"
  input.path == "/compare"
}

allow if {
  input.method == "GET"
  startswith(input.path, "/static/")
}
'@ | Set-Content -Path (Join-Path $tmpDir "policy.rego")

@'
{
  "name": "knowledge-graph-access-policy",
  "version": "1.0.0"
}
'@ | Set-Content -Path (Join-Path $tmpDir "metadata.json")

$bundleImage = "$repo/knowledge-graph-access-policy:$tag"
tar -C $tmpDir -cf (Join-Path $tmpDir "bundle.tar") policy.rego metadata.json
oras push --disable-path-validation $bundleImage (Join-Path $tmpDir "bundle.tar:application/vnd.oci.image.layer.v1.tar")
