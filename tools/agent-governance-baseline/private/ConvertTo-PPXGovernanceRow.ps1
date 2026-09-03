function ConvertTo-PPXGovernanceRow {
    <#
    .SYNOPSIS
        Shapes one joined Inventory API record into a flat governance-baseline row.
    .DESCRIPTION
        See PPXAgentGovernanceBaseline.md §5 for the base schema. This pass populates everything
        derivable from the Inventory API response itself (Connect-PPXInventoryApi) -- no Graph, DLP,
        or connector-catalog lookups. Columns whose source is one of those unimplemented steps
        (Resolve-PPXOwnerIdentity, Get-PPXDlpCoverageFlag, Resolve-PPXConnectorTier) are emitted as
        an explicit empty string, never $false/0/'Unknown', so a blank can never be misread as a
        real negative finding.

        Field paths below were confirmed against a live tenant response (2026-09-03) except where
        noted "inferred" -- those are still best-effort. See CHANGELOG.md for the confirmation pass.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] $Record
    )

    process {
        $properties = Get-PPXNestedValue $Record 'properties' -Default $null

        # --- Publish staleness -------------------------------------------------------------
        $lastPublishedRaw = Get-PPXNestedValue $properties 'lastPublishedAt' -Default $null
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

        # CreatedAt has been observed as a live [datetime] object (not a plain ISO string) in at
        # least one PowerShell version/host combination -- normalise to ISO 8601 either way so the
        # CSV is locale-independent and sortable, instead of whatever ToString() the console used.
        $createdAtRaw = Get-PPXNestedValue $properties 'createdAt' -Default $null
        $createdAt = $createdAtRaw
        if ($createdAtRaw) {
            try { $createdAt = ([datetime] $createdAtRaw).ToString('o') } catch { }
        }

        # --- Identity model ------------------------------------------------------------------
        # Confirmed: entraAgentId / entraAgentBlueprintId presence => "Entra Agent ID/Blueprint".
        # The "legacy Entra app only" / "neither" branches are inferred (no live example of either
        # has been seen yet) from AuthenticationMode alone -- revisit if that turns out to be wrong.
        $entraAgentId = Get-PPXNestedValue $properties 'entraAgentId' -Default ''
        $entraAgentBlueprintId = Get-PPXNestedValue $properties 'entraAgentBlueprintId' -Default ''
        $authenticationMode = Get-PPXNestedValue $properties 'authentication' -Default ''
        $identityModel =
            if ($entraAgentId -or $entraAgentBlueprintId) { 'Entra Agent ID/Blueprint' }
            elseif ($authenticationMode -and $authenticationMode -ne 'None') { 'Legacy Entra app (inferred)' }
            else { 'None' }

        # --- Connector / flow counts -----------------------------------------------------------
        # capabilitiesCounts (confirmed shape: distinctPowerPlatformConnectors /
        # distinctPowerPlatformConnectorsOperations / distinctFlows) is authoritative -- prefer it
        # over manually counting the powerPlatformConnectors array, which is also used as a
        # truncation signal: if the array actually returned is shorter than the reported distinct
        # count, the API held some connectors back.
        $capabilitiesCounts = Get-PPXNestedValue $properties 'capabilitiesCounts' -Default $null
        $connectorsArray = @(Get-PPXNestedValue $properties 'powerPlatformConnectors' -Default @())
        $reportedConnectorCount = Get-PPXNestedValue $capabilitiesCounts 'distinctPowerPlatformConnectors' -Default $null

        $distinctConnectorCount =
            if ($null -ne $reportedConnectorCount) { [int] $reportedConnectorCount }
            else {
                (
                    $connectorsArray | ForEach-Object {
                        if ($_.connectorId) { $_.connectorId } else { $_ | ConvertTo-Json -Compress -Depth 5 }
                    } | Select-Object -Unique
                ).Count
            }

        $capabilitiesTruncated = ($null -ne $reportedConnectorCount) -and ($connectorsArray.Count -lt [int] $reportedConnectorCount)

        # --- Channels / triggers / flows (requested; item shape unconfirmed, see helper) --------
        $channelsSummary = ConvertTo-PPXArraySummary -Items @(Get-PPXNestedValue $properties 'channels' -Default @())
        $triggersSummary = ConvertTo-PPXArraySummary -Items @(Get-PPXNestedValue $properties 'triggers' -Default @())
        $flowsSummary = ConvertTo-PPXArraySummary -Items @(Get-PPXNestedValue $properties 'flows' -Default @())

        # --- Sharing exposure ---------------------------------------------------------------
        $sharedWithViewers = Get-PPXNestedValue $properties 'sharedWithViewers' -Default $null

        # --- Component composition -----------------------------------------------------------
        $componentsCounts = Get-PPXNestedValue $properties 'componentsCounts' -Default $null

        [PSCustomObject][ordered]@{
            # --- Identity / location -----------------------------------------------------
            AgentName             = Get-PPXNestedValue $properties 'displayName' -Default ''
            AgentId               = Get-PPXNestedValue $Record 'name' -Default ''
            SchemaName            = Get-PPXNestedValue $properties 'schemaName' -Default ''
            EnvironmentName       = Get-PPXNestedValue $Record 'environmentName' -Default ''
            EnvironmentId         = Get-PPXNestedValue $properties 'environmentId' -Default ''
            EnvironmentType       = Get-PPXNestedValue $Record 'environmentType' -Default ''
            IsManagedEnvironment  = Get-PPXNestedValue $Record 'isManagedEnvironment' -Default ''
            EnvironmentGroup      = ''   # not projected by the current Inventory API query -- see known limitations

            # --- Ownership (Graph resolution not implemented yet -- raw IDs only) --------
            OwnerName             = ''   # requires Resolve-PPXOwnerIdentity -- not implemented yet
            OwnerUPN              = ''   # requires Resolve-PPXOwnerIdentity -- not implemented yet
            OwnerAccountStatus    = ''   # requires Resolve-PPXOwnerIdentity -- not implemented yet
            OwnerId               = Get-PPXNestedValue $properties 'ownerId' -Default ''

            # --- Lifecycle -----------------------------------------------------------------
            CreatedAt             = $createdAt
            LastPublishedAt       = if ($lastPublishedAt) { $lastPublishedAt.ToString('o') } else { '' }
            StalenessBucket       = $stalenessBucket
            IsQuarantined         = Get-PPXNestedValue $properties 'isQuarantined' -Default ''

            # --- Auth / identity -------------------------------------------------------------
            AuthenticationMode    = $authenticationMode
            IdentityModel         = $identityModel
            EntraAgentId          = $entraAgentId

            # --- Build origin ----------------------------------------------------------------
            CreatedIn             = Get-PPXNestedValue $properties 'createdIn' -Default ''
            Harness               = Get-PPXNestedValue $properties 'harness' -Default ''
            Model                 = Get-PPXNestedValue $properties 'model' -Default ''
            OrchestrationType     = Get-PPXNestedValue $properties 'orchestration' -Default ''
            IsCLIAgent            = Get-PPXNestedValue $properties 'isCLIAgent' -Default ''
            IsGithubCopilotAgent  = Get-PPXNestedValue $properties 'isGithubCopilotAgent' -Default ''
            IsManagedAgent        = Get-PPXNestedValue $properties 'isManaged' -Default ''   # agent-level flag; distinct from IsManagedEnvironment

            # --- Connectivity / automation surface --------------------------------------------
            DistinctConnectorCount  = $distinctConnectorCount
            PremiumConnectorCount    = ''   # requires Resolve-PPXConnectorTier -- not implemented yet
            CapabilitiesTruncated    = $capabilitiesTruncated
            ChannelsCount            = $channelsSummary.Count
            Channels                 = $channelsSummary.Summary
            TriggersCount            = $triggersSummary.Count
            Triggers                 = $triggersSummary.Summary
            FlowsCount               = $flowsSummary.Count
            Flows                    = $flowsSummary.Summary

            # --- Composition / content ---------------------------------------------------------
            TopicsCount             = [int] (Get-PPXNestedValue $componentsCounts 'topics' -Default 0)
            ToolsCount              = [int] (Get-PPXNestedValue $componentsCounts 'tools' -Default 0)
            KnowledgeCount          = [int] (Get-PPXNestedValue $componentsCounts 'knowledge' -Default 0)
            ConnectedAgentsCount    = [int] (Get-PPXNestedValue $componentsCounts 'connectedAgents' -Default 0)
            InstructionsCharactersCount     = [int] (Get-PPXNestedValue $properties 'instructionsCharactersCount' -Default 0)
            IsWebSearchEnabledForKnowledge  = Get-PPXNestedValue $properties 'isWebSearchEnabledForKnowledge' -Default ''

            # --- Sharing exposure ----------------------------------------------------------------
            SharedWithEntireTenant = Get-PPXNestedValue $sharedWithViewers 'entireTenant' -Default ''

            # --- Governance flags requiring future enrichment ------------------------------------
            HasZeroDlpCoverage     = ''   # requires Get-PPXDlpCoverageFlag -- not implemented yet
        }
    }
}
