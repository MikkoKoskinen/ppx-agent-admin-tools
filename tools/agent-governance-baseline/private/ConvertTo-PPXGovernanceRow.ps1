function ConvertTo-PPXGovernanceRow {
    <#
    .SYNOPSIS
        Shapes one joined Inventory API record into a flat §5 governance-baseline row.
    .DESCRIPTION
        See PPXAgentGovernanceBaseline.md §5 for the target schema. This pass populates only what's
        derivable from the Inventory API response itself (Connect-PPXInventoryApi) — no Graph, DLP,
        or connector-catalog lookups. Columns whose source is one of those unimplemented steps
        (Resolve-PPXOwnerIdentity, Get-PPXDlpCoverageFlag, Resolve-PPXConnectorTier) are emitted as
        an explicit empty string, never $false/0/'Unknown', so a blank can never be misread as a
        real negative finding.

        Several field paths below (SchemaName, LastPublishedAt, IsQuarantined, IdentityModel) are
        NOT confirmed against a live API response — no sample has ever been captured in this repo.
        They are best-effort guesses, marked inline. Confirm them against a real tenant
        ($raw.data[0] | ConvertTo-Json -Depth 10) and correct here before trusting this report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] $Record
    )

    process {
        $lastPublishedRaw = Get-PPXNestedValue $Record 'properties.lastPublishedOn' -Default $null
        $lastPublishedAt = $null
        if ($lastPublishedRaw) {
            try { $lastPublishedAt = [datetime] $lastPublishedRaw } catch { }
        }

        $stalenessBucket =
            if (-not $lastPublishedAt) { 'Unknown' }
            elseif ($lastPublishedAt -ge (Get-Date).AddMonths(-6)) { '<6mo' }
            elseif ($lastPublishedAt -ge (Get-Date).AddMonths(-12)) { '6-12mo' }
            elseif ($lastPublishedAt -ge (Get-Date).AddMonths(-24)) { '12-24mo' }
            else { '>24mo' }

        $connectors = @(Get-PPXNestedValue $Record 'properties.powerPlatformConnectors' -Default @())
        $distinctConnectorCount = (
            $connectors | ForEach-Object {
                if ($_.id) { $_.id }
                elseif ($_.connectorName) { $_.connectorName }
                elseif ($_.name) { $_.name }
                else { $_ | ConvertTo-Json -Compress -Depth 5 }
            } | Select-Object -Unique
        ).Count

        $capabilitiesRaw = Get-PPXNestedValue $Record 'properties.capabilitiesCounts' -Default $null
        $capabilitiesTruncated =
            if ($capabilitiesRaw -is [int] -or $capabilitiesRaw -is [long]) { $capabilitiesRaw -ge 200 }
            elseif ($capabilitiesRaw) {
                $values = if ($capabilitiesRaw -is [System.Collections.IDictionary]) {
                    $capabilitiesRaw.Values
                }
                else {
                    $capabilitiesRaw.PSObject.Properties.Value
                }
                [bool] ($values | Where-Object { $_ -ge 200 } | Select-Object -First 1)
            }
            else { $false }

        [PSCustomObject][ordered]@{
            AgentName             = Get-PPXNestedValue $Record 'properties.displayName' -Default ''
            AgentId               = Get-PPXNestedValue $Record 'name' -Default ''
            SchemaName            = Get-PPXNestedValue $Record 'properties.schemaName' -Default ''   # unverified path
            EnvironmentName       = Get-PPXNestedValue $Record 'environmentName' -Default ''
            EnvironmentId         = Get-PPXNestedValue $Record 'properties.environmentId' -Default ''
            EnvironmentType       = Get-PPXNestedValue $Record 'environmentType' -Default ''
            IsManagedEnvironment  = Get-PPXNestedValue $Record 'isManagedEnvironment' -Default ''
            EnvironmentGroup      = ''   # not projected by the current Inventory API query — see known limitations
            OwnerName             = ''   # requires Resolve-PPXOwnerIdentity — not implemented yet
            OwnerUPN              = ''   # requires Resolve-PPXOwnerIdentity — not implemented yet
            OwnerAccountStatus    = ''   # requires Resolve-PPXOwnerIdentity — not implemented yet
            CreatedAt             = Get-PPXNestedValue $Record 'properties.createdAt' -Default ''
            LastPublishedAt       = if ($lastPublishedAt) { $lastPublishedAt.ToString('o') } else { '' }   # unverified path
            StalenessBucket       = $stalenessBucket
            AuthenticationMode    = Get-PPXNestedValue $Record 'properties.authentication' -Default ''
            IdentityModel         = 'Unknown'   # no known single source path — needs live-data investigation
            OrchestrationType     = Get-PPXNestedValue $Record 'properties.orchestration' -Default ''
            DistinctConnectorCount = $distinctConnectorCount
            PremiumConnectorCount  = ''   # requires Resolve-PPXConnectorTier — not implemented yet
            HasZeroDlpCoverage     = ''   # requires Get-PPXDlpCoverageFlag — not implemented yet
            CapabilitiesTruncated  = $capabilitiesTruncated
            IsQuarantined          = Get-PPXNestedValue $Record 'properties.isQuarantined' -Default ''   # unverified path
            ChannelDataAvailable   = $false
            EnvironmentRegion      = Get-PPXNestedValue $Record 'environmentRegion' -Default ''   # bonus column, not in §5
        }
    }
}
