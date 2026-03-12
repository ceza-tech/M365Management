#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Reusable mock responses for Microsoft Graph API calls
#>

# Mock responses for UTCM Configuration Monitor API
$script:MockMonitorResponses = @{

    # GET /admin/configurationManagement/configurationMonitors
    ListMonitors = @{
        value = @(
            @{
                id = '11111111-1111-1111-1111-111111111111'
                displayName = 'Testcorp GitOps'
                description = 'GitOps monitor for testcorp tenant'
                status = 'active'
                createdDateTime = '2026-01-15T10:30:00Z'
                lastModifiedDateTime = '2026-03-10T14:22:00Z'
            }
        )
    }

    # GET /admin/configurationManagement/configurationMonitors/{id}
    GetMonitor = @{
        id = '11111111-1111-1111-1111-111111111111'
        displayName = 'Testcorp GitOps'
        description = 'GitOps monitor for testcorp tenant'
        status = 'active'
        baseline = @{
            resources = @(
                @{
                    resourceType = 'microsoft.entra.conditionalaccesspolicy'
                    properties = @{
                        Id = '12345678-1234-1234-1234-123456789012'
                        DisplayName = 'Require MFA for All Users'
                        State = 'enabled'
                        Ensure = 'Present'
                    }
                }
            )
        }
    }

    # POST /admin/configurationManagement/configurationMonitors
    CreateMonitor = @{
        id = '22222222-2222-2222-2222-222222222222'
        displayName = 'Newcorp GitOps'
        status = 'active'
        createdDateTime = '2026-03-11T09:00:00Z'
    }

    # PATCH /admin/configurationManagement/configurationMonitors/{id}
    UpdateMonitor = @{
        id = '11111111-1111-1111-1111-111111111111'
        displayName = 'Testcorp GitOps'
        status = 'active'
        lastModifiedDateTime = '2026-03-11T09:05:00Z'
    }
}

# Mock responses for UTCM Snapshot API
$script:MockSnapshotResponses = @{

    # POST /admin/configurationManagement/configurationSnapshots/createSnapshot
    CreateSnapshotJob = @{
        id = 'job-33333333-3333-3333-3333-333333333333'
        displayName = 'Snapshot 20260311 090000'
        status = 'running'
        createdDateTime = '2026-03-11T09:00:00Z'
    }

    # GET /admin/configurationManagement/configurationSnapshotJobs/{id} - Running
    SnapshotJobRunning = @{
        id = 'job-33333333-3333-3333-3333-333333333333'
        displayName = 'Snapshot 20260311 090000'
        status = 'running'
        createdDateTime = '2026-03-11T09:00:00Z'
    }

    # GET /admin/configurationManagement/configurationSnapshotJobs/{id} - Succeeded
    SnapshotJobSucceeded = @{
        id = 'job-33333333-3333-3333-3333-333333333333'
        displayName = 'Snapshot 20260311 090000'
        status = 'succeeded'
        createdDateTime = '2026-03-11T09:00:00Z'
        completedDateTime = '2026-03-11T09:01:30Z'
        resourceLocation = 'https://graph.microsoft.com/beta/admin/configurationManagement/configurationSnapshots/snap-44444444'
    }

    # GET /admin/configurationManagement/configurationSnapshots/{id}
    GetSnapshot = @{
        id = 'snap-44444444-4444-4444-4444-444444444444'
        displayName = 'Snapshot 20260311 090000'
        createdDateTime = '2026-03-11T09:01:30Z'
        resources = @(
            @{
                resourceType = 'microsoft.entra.conditionalaccesspolicy'
                properties = @{
                    Id = '12345678-1234-1234-1234-123456789012'
                    DisplayName = 'Require MFA for All Users'
                    State = 'enabled'
                    CreatedDateTime = '2025-06-01T10:00:00Z'
                }
            },
            @{
                resourceType = 'microsoft.entra.securitydefaults'
                properties = @{
                    Id = 'secdef-00000000-0000-0000-0000-000000000000'
                    IsEnabled = $false
                }
            }
        )
    }
}

# Mock responses for UTCM Drift Detection API
$script:MockDriftResponses = @{

    # GET /admin/configurationManagement/configurationDrifts - No drifts
    NoDrifts = @{
        value = @()
    }

    # GET /admin/configurationManagement/configurationDrifts - With drifts
    WithDrifts = @{
        value = @(
            @{
                id = 'drift-55555555-5555-5555-5555-555555555555'
                monitorId = '11111111-1111-1111-1111-111111111111'
                resourceType = 'microsoft.entra.conditionalaccesspolicy'
                resourceId = '12345678-1234-1234-1234-123456789012'
                detectedDateTime = '2026-03-11T08:00:00Z'
                driftedProperties = @(
                    @{
                        propertyName = 'State'
                        baselineValue = 'enabled'
                        currentValue = 'disabled'
                    }
                )
            }
        )
    }
}

# Helper function to create a mock Invoke-GraphRequest that returns appropriate responses
function New-GraphApiMock {
    param(
        [hashtable]$ResponseMap = @{}
    )

    return {
        param(
            [string]$Method = 'GET',
            [string]$Endpoint,
            [object]$Body = $null,
            [string]$Token
        )

        # Default responses based on endpoint
        switch -Regex ($Endpoint) {
            '/configurationMonitors$' {
                if ($Method -eq 'GET') { return $script:MockMonitorResponses.ListMonitors }
                if ($Method -eq 'POST') { return $script:MockMonitorResponses.CreateMonitor }
            }
            '/configurationMonitors/[^/]+$' {
                if ($Method -eq 'GET') { return $script:MockMonitorResponses.GetMonitor }
                if ($Method -eq 'PATCH') { return $script:MockMonitorResponses.UpdateMonitor }
            }
            '/createSnapshot$' {
                return $script:MockSnapshotResponses.CreateSnapshotJob
            }
            '/configurationSnapshotJobs/[^/]+$' {
                return $script:MockSnapshotResponses.SnapshotJobSucceeded
            }
            '/configurationSnapshots/[^/]+$' {
                return $script:MockSnapshotResponses.GetSnapshot
            }
            '/configurationDrifts$' {
                return $script:MockDriftResponses.NoDrifts
            }
            default {
                Write-Warning "Unmocked endpoint: $Method $Endpoint"
                return @{}
            }
        }
    }
}

Export-ModuleMember -Function New-GraphApiMock -Variable MockMonitorResponses, MockSnapshotResponses, MockDriftResponses
