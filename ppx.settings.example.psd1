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
#   - Leave a value as '' (empty string), 0, or $false to mean "not set — use the default".
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

        # Page size passed to the Inventory API query. 0 = use the API default.
        Top = 0
    }
}
