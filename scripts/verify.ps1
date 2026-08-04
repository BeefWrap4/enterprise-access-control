$ErrorActionPreference = "Stop"

$realm = "http://localhost:8180/realms/baseops"
$tokenEndpoint = "$realm/protocol/openid-connect/token"

function Get-AccessToken([string]$Username, [string]$Password) {
    $response = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -ContentType "application/x-www-form-urlencoded" -Body @{
        grant_type    = "password"
        client_id     = "qa-client"
        client_secret = "qa-client-dev-secret"
        username      = $Username
        password      = $Password
        scope         = "openid profile email"
    }
    return $response.access_token
}

function Get-ServiceToken([string]$ClientId, [string]$ClientSecret) {
    $response = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -ContentType "application/x-www-form-urlencoded" -Body @{
        grant_type = "client_credentials"
        client_id = $ClientId
        client_secret = $ClientSecret
    }
    return $response.access_token
}

function Get-Status([string]$Uri, [string]$Method = "Get", [string]$Token = "", [object]$Body = $null) {
    $headers = @{}
    if ($Token) { $headers.Authorization = "Bearer $Token" }
    try {
        $params = @{ Uri = $Uri; Method = $Method; Headers = $headers; UseBasicParsing = $true }
        if ($null -ne $Body) {
            $params.ContentType = "application/json"
            $params.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
        }
        return (Invoke-WebRequest @params).StatusCode
    }
    catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        throw
    }
}

function Assert-Equal([object]$Actual, [object]$Expected, [string]$Name) {
    if ($Actual -ne $Expected) { throw "$Name expected=$Expected actual=$Actual" }
    Write-Host "[PASS] $Name -> $Actual"
}

Assert-Equal (Get-Status "http://localhost:8180/realms/baseops/.well-known/openid-configuration") 200 "Keycloak discovery"
Assert-Equal (Get-Status "http://localhost:3592/_cerbos/health") 200 "Cerbos health"

$opsToken = Get-AccessToken "ops-user" "Ops-demo-2026!"
$viewerToken = Get-AccessToken "viewer-user" "Viewer-demo-2026!"
$otherToken = Get-AccessToken "other-workspace-user" "Other-demo-2026!"
$mcpToken = Get-ServiceToken "agent-mcp" "agent-mcp-dev-secret"
$ragCacheToken = Get-ServiceToken "rag-cache-client" "rag-cache-client-dev-secret"
$agentModelToken = Get-ServiceToken "agent-model-client" "agent-model-client-dev-secret"

foreach ($port in 8101, 8102, 8103) {
    Assert-Equal (Get-Status "http://localhost:$port/health/ready") 200 "API $port readiness"
    Assert-Equal (Get-Status "http://localhost:$port/api/v1/auth/me") 401 "API $port rejects missing token"
    Assert-Equal (Get-Status "http://localhost:$port/api/v1/auth/me" "Get" $opsToken) 200 "API $port accepts ops token"
}

Assert-Equal (Get-Status "http://localhost:8101/api/v1/documents" "Get" $viewerToken) 403 "RAG rejects viewer role"
$serviceMe = Invoke-RestMethod -Uri "http://localhost:8101/api/v1/auth/me" -Headers @{ Authorization = "Bearer $mcpToken" }
Assert-Equal $serviceMe.service $true "RAG accepts MCP service identity"
Assert-Equal ($serviceMe.roles -contains "rag-search-service") $true "MCP service identity carries query-only role"
Assert-Equal ($serviceMe.roles -contains "ops") $false "MCP service identity does not carry broad ops role"
$ragCacheMe = Invoke-RestMethod -Uri "http://localhost:8102/api/v1/auth/me" -Headers @{ Authorization = "Bearer $ragCacheToken" }
Assert-Equal $ragCacheMe.service $true "RAG model client is accepted by cache gateway"
$agentModelMe = Invoke-RestMethod -Uri "http://localhost:8102/api/v1/auth/me" -Headers @{ Authorization = "Bearer $agentModelToken" }
Assert-Equal $agentModelMe.service $true "Agent model client is accepted by cache gateway"
$otherDocuments = Invoke-RestMethod -Uri "http://localhost:8101/api/v1/documents" -Headers @{ Authorization = "Bearer $otherToken" }
Assert-Equal @($otherDocuments).Count 0 "RAG filters another workspace"

$runBody = @{ scenario = "alarm-log-diagnosis"; query = "authorization negative test"; workspace_id = "demo" }
Assert-Equal (Get-Status "http://localhost:8103/api/v1/runs" "Post" $viewerToken $runBody) 403 "Agent rejects viewer run creation"

$cerbosBase = @{
    requestId = "verify-$([guid]::NewGuid().ToString('N'))"
    principal = @{ id = "ops-user"; roles = @("ops"); attr = @{ workspace_id = "demo" } }
}
$allowBody = $cerbosBase.Clone()
$allowBody.resources = @(@{ resource = @{ kind = "agent_tool"; id = "alarm/query"; attr = @{ workspace_id = "demo"; station_allowed = $true; long_window = $false; risk = "L1"; approval_consumed = $false } }; actions = @("execute") })
$allow = Invoke-RestMethod -Method Post -Uri "http://localhost:3592/api/check/resources" -ContentType "application/json" -Body ($allowBody | ConvertTo-Json -Depth 10)
Assert-Equal $allow.results[0].actions.execute "EFFECT_ALLOW" "Cerbos allows scoped L1 tool"

$denyBody = $cerbosBase.Clone()
$denyBody.requestId = "verify-$([guid]::NewGuid().ToString('N'))"
$denyBody.resources = @(@{ resource = @{ kind = "agent_tool"; id = "ops/archive"; attr = @{ workspace_id = "demo"; station_allowed = $true; long_window = $false; risk = "L3"; approval_consumed = $false } }; actions = @("execute") })
$deny = Invoke-RestMethod -Method Post -Uri "http://localhost:3592/api/check/resources" -ContentType "application/json" -Body ($denyBody | ConvertTo-Json -Depth 10)
Assert-Equal $deny.results[0].actions.execute "EFFECT_DENY" "Cerbos denies unconsumed L3 tool"

Write-Host "Enterprise access-control verification passed."
