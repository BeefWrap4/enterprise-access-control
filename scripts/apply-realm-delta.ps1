param(
    [string]$KeycloakBaseUrl = "http://localhost:8180",
    [string]$AdminUsername = $(if ($env:KEYCLOAK_ADMIN) { $env:KEYCLOAK_ADMIN } else { "admin" }),
    [string]$AdminPassword = $(if ($env:KEYCLOAK_ADMIN_PASSWORD) { $env:KEYCLOAK_ADMIN_PASSWORD } else { "admin-dev-only" })
)

$ErrorActionPreference = "Stop"

$realmName = "baseops"
$realmFile = Join-Path $PSScriptRoot "..\keycloak\realm-baseops.json"
$realm = Get-Content -Raw -Encoding utf8 $realmFile | ConvertFrom-Json

function Get-AdminToken {
    $response = Invoke-RestMethod -Method Post `
        -Uri "$KeycloakBaseUrl/realms/master/protocol/openid-connect/token" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body @{
            grant_type = "password"
            client_id = "admin-cli"
            username = $AdminUsername
            password = $AdminPassword
        }
    return $response.access_token
}

$token = Get-AdminToken
$headers = @{ Authorization = "Bearer $token" }
$adminBase = "$KeycloakBaseUrl/admin/realms/$realmName"

function Invoke-KeycloakAdmin {
    param(
        [ValidateSet("Get", "Post", "Put", "Delete")][string]$Method,
        [string]$Path,
        [object]$Body = $null
    )
    $params = @{
        Method = $Method
        Uri = "$adminBase$Path"
        Headers = $headers
    }
    if ($null -ne $Body) {
        $params.ContentType = "application/json"
        $params.Body = ConvertTo-Json -InputObject $Body -Depth 30 -Compress
    }
    Invoke-RestMethod @params
}

function Get-RealmRole([string]$RoleName) {
    return Invoke-KeycloakAdmin -Method Get -Path "/roles/$([uri]::EscapeDataString($RoleName))"
}

function Ensure-RealmRole([object]$RoleDefinition) {
    try {
        $existing = Get-RealmRole $RoleDefinition.name
        Invoke-KeycloakAdmin -Method Put -Path "/roles/$([uri]::EscapeDataString($RoleDefinition.name))" -Body $RoleDefinition
        Write-Host "[SYNC] updated realm role $($existing.name)"
    }
    catch {
        if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw }
        Invoke-KeycloakAdmin -Method Post -Path "/roles" -Body $RoleDefinition
        Write-Host "[SYNC] created realm role $($RoleDefinition.name)"
    }
}

function Get-Client([string]$ClientId) {
    $items = @(Invoke-KeycloakAdmin -Method Get -Path "/clients?clientId=$([uri]::EscapeDataString($ClientId))")
    if ($items.Count -eq 0) { return $null }
    return $items[0]
}

function Ensure-Client([object]$ClientDefinition) {
    $existing = Get-Client $ClientDefinition.clientId
    if ($null -eq $existing) {
        Invoke-KeycloakAdmin -Method Post -Path "/clients" -Body $ClientDefinition
        $existing = Get-Client $ClientDefinition.clientId
        Write-Host "[SYNC] created client $($ClientDefinition.clientId)"
    }
    else {
        Invoke-KeycloakAdmin -Method Put -Path "/clients/$($existing.id)" -Body $ClientDefinition
        $existing = Get-Client $ClientDefinition.clientId
        Write-Host "[SYNC] updated client $($ClientDefinition.clientId)"
    }
    return $existing
}

function Set-ServiceAccountRoles([object]$Client, [string[]]$ExpectedRoles, [string[]]$RemovedRoles = @()) {
    $serviceUser = Invoke-KeycloakAdmin -Method Get -Path "/clients/$($Client.id)/service-account-user"
    foreach ($roleName in $ExpectedRoles) {
        $role = Get-RealmRole $roleName
        Invoke-KeycloakAdmin -Method Post -Path "/users/$($serviceUser.id)/role-mappings/realm" -Body @($role)
    }
    foreach ($roleName in $RemovedRoles) {
        $role = Get-RealmRole $roleName
        Invoke-KeycloakAdmin -Method Delete -Path "/users/$($serviceUser.id)/role-mappings/realm" -Body @($role)
    }
    Write-Host "[SYNC] service account roles $($Client.clientId): $($ExpectedRoles -join ', ')"
}

foreach ($roleName in "rag-search-service", "knowledge-version-publisher", "session-delegator") {
    $role = $realm.roles.realm | Where-Object name -eq $roleName
    Ensure-RealmRole $role
}

$clientRoles = @{
    "agent-mcp" = @("service", "rag-search-service")
    "rag-cache-client" = @("service", "knowledge-version-publisher", "session-delegator")
    "agent-model-client" = @("service", "session-delegator")
}

foreach ($clientId in $clientRoles.Keys) {
    $definition = $realm.clients | Where-Object clientId -eq $clientId
    if ($null -eq $definition) { throw "Client definition not found: $clientId" }
    $client = Ensure-Client $definition
    $removedRoles = if ($clientId -eq "agent-mcp") { @("ops") } else { @() }
    Set-ServiceAccountRoles -Client $client -ExpectedRoles $clientRoles[$clientId] -RemovedRoles $removedRoles
}

Write-Host "Keycloak realm delta applied without resetting persistent data."
