#
# PPX Agent Admin Tools — shared user settings (TEMPLATE)
#
# HOW TO USE
#   1. Copy this file to  ppx.settings.psd1  in the same folder (the repo root).
#   2. Edit the values in your copy. ppx.settings.psd1 is git-ignored, so your
#      tenant-specific values never get committed.
#   3. Run any tool normally — it reads ppx.settings.psd1 automatically.
#
# NOTES
#   - This is a PowerShell *data* file: values only, no commands. It is parsed
#     with Import-PowerShellDataFile, which never executes code.
#   - An explicit parameter passed on the command line always wins over a value
#     set here. A value set here always wins over the tool/API default.
#   - Leave a value as '' (empty string) or 0 to mean "not set — use the default".
#   - $false is a real value, not an "unset" placeholder — for a setting whose default is $true
#     (e.g. AgentGovernanceBaseline.ExportReport), setting it to $false here genuinely turns it off.
#   - A key in a tool section overrides the same key in Common for that tool.
#
@{

    # ---------------------------------------------------------------------------
    # Common — applies to every PPX tool unless a tool section overrides it.
    # ---------------------------------------------------------------------------
    Common = @{

        # REQUIRED. Entra (Azure AD) tenant ID to sign in against. The tools refuse to run
        # until this is set (in your ppx.settings.psd1) or passed as -TenantId.
        # Example: '00000000-0000-0000-0000-000000000000'
        TenantId = ''

        # Set to $true if the interactive browser sign-in never completes — e.g. when running
        # inside the VS Code debugger / PowerShell Integrated Console, where the Windows WAM
        # account prompt hangs. Uses device-code sign-in instead: a code + URL are printed for
        # you to complete in any browser.
        UseDeviceAuthentication = $false
    }

    # ---------------------------------------------------------------------------
    # tools/agent-governance-baseline
    # ---------------------------------------------------------------------------
    AgentGovernanceBaseline = @{

        # TenantId = ''   # uncomment to use a different tenant for just this tool

        # Rows fetched per Inventory API request (1-1000; values above 1000 are clamped, the API
        # will not return more in one page). 0 = use the default (1000). This does NOT cap the
        # total: the tool follows skipToken paging until every agent record is retrieved.
        Top = 0

        # Safety cap on how many Inventory API pages to follow. 0 = no cap (retrieve everything).
        # Set a small number for a quick partial pull while testing -- the report is then flagged
        # INCOMPLETE in its .limitations.txt sidecar.
        MaxPages = 0

        # Where the CSV report (and its .limitations.txt sidecar) is written. A folder path
        # auto-names a timestamped file into it; a path ending in .csv is used as-is.
        # '' = use the default reports\ folder at the repo root (git-ignored).
        OutputPath = ''

        # Whether to write the CSV report (and its .limitations.txt sidecar) to disk.
        # $false means: only build and return the shaped rows in memory, write nothing to disk.
        ExportReport = $true
    }

    # ---------------------------------------------------------------------------
    # tools/custom-connector-usage
    # ---------------------------------------------------------------------------
    CustomConnectorUsage = @{

        # TenantId = ''   # uncomment to use a different tenant for just this tool

        # Rows fetched per Inventory API request (1-1000; values above 1000 are clamped). 0 = default
        # (1000). This does NOT cap the total: the tool follows skipToken paging until every
        # connector-emitting resource (apps, flows, agents) has been retrieved.
        Top = 0

        # Safety cap on how many Inventory API pages to follow per query. 0 = no cap (retrieve
        # everything). A small number gives a quick partial pull while testing -- the report is then
        # flagged INCOMPLETE in its .limitations.txt sidecar.
        MaxPages = 0

        # Cap on how many environments the per-environment connector lookup (connectivity API) runs
        # against. 0 = all. Set a small number for a quick test; the report notes partial coverage.
        MaxEnvironments = 0

        # $true = skip the per-environment connectivity calls entirely. Fast, but the report is then
        # built from the Inventory usage heuristic alone: only custom connectors that a resource
        # references appear, IsCustomApi is "Inferred", ExistsInEnvironmentList is "Unknown".
        SkipEnvironmentConnectorLookup = $false

        # Where the CSV report (and its .limitations.txt sidecar) is written. A folder path
        # auto-names a timestamped file into it; a path ending in .csv is used as-is.
        # '' = use the default reports\ folder at the repo root (git-ignored).
        OutputPath = ''

        # Whether to write the CSV report (and its .limitations.txt sidecar) to disk.
        # $false means: only build and return the shaped rows in memory, write nothing to disk.
        ExportReport = $true

        # $true = also emit one placeholder row for every environment that has NO custom connectors
        # (blank ConnectorId), so the CSV doubles as a "confirmed clean" list. $false (default) =
        # only rows for environments that have at least one custom connector.
        IncludeAllEnvironments = $false
    }

    # ---------------------------------------------------------------------------
    # tools/copilot-credit-tenant-pool
    #
    # Sets the Copilot Credit "Draw from the available capacity in my tenant" option (the TenantPool
    # enforcement rule on the MCSMessages currency allocation) for all or selected environments.
    #
    # The change intent is ALWAYS passed on the command line, never from this file:
    #   -DrawFromTenantCapacity $true|$false   (required)   the value to set
    #   -EnvironmentId <guid[,guid...]>  or  -AllEnvironments   (exactly one)   the targets
    #   -Apply                                                  actually write (default = dry run)
    # ---------------------------------------------------------------------------
    CopilotCreditTenantPool = @{

        # TenantId = ''   # uncomment to use a different tenant for just this tool

        # Inventory API page size for the environment list (1-1000; values above 1000 are clamped).
        # 0 = default (1000). Does NOT cap the total -- skipToken paging retrieves every environment.
        Top = 0

        # Safety cap on Inventory API pages for the environment list. 0 = no cap. A small number
        # gives a quick partial pull while testing; the environment list is then flagged INCOMPLETE
        # and (with -AllEnvironments) some environments are missed.
        MaxPages = 0

        # Where the CSV report (and its .limitations.txt sidecar) is written. A folder path
        # auto-names a timestamped file into it; a path ending in .csv is used as-is.
        # '' = use the default reports\ folder at the repo root (git-ignored).
        OutputPath = ''

        # Whether to write the CSV report (and its .limitations.txt sidecar) to disk.
        # $false means: only read + shape the rows in memory, write nothing to disk.
        ExportReport = $true
    }
}
