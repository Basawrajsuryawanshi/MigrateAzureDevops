```powershell
# =====================================================================
# Azure DevOps Project Migration Script
# =====================================================================
#
# Migrates ONE Azure DevOps project from one organization to another.
#
# Migrates:
#   - Project
#   - Git repositories
#   - Full Git history
#   - Branches
#   - Tags
#   - Variable Groups
#   - Non-secret Variable Group variables
#   - YAML pipeline definitions where possible
#
# Exports for manual recreation:
#   - Service Connections
#   - Environments
#   - Additional project configuration
#
# Does NOT migrate:
#   - Secret variable values
#   - Service connection credentials/secrets
#   - Build history
#   - Release history
#   - Work item history
#   - Branch policies/permissions automatically
#
# =====================================================================

param(
    [switch]$DryRun
)

# =====================================================================
# 1. CONFIGURATION - CHANGE THESE VALUES
# =====================================================================

$OldOrg = "https://dev.azure.com/OLD_ORGANIZATION"
$NewOrg = "https://dev.azure.com/NEW_ORGANIZATION"

$ProjectName = "YOUR_PROJECT_NAME"

# Optional:
# Set this if the new project should have a different name.
# Leave it the same if you want the same project name.
$NewProjectName = $ProjectName

# Migration working directory
$MigrationRoot = "C:\AzureDevOpsMigration"

# =====================================================================
# 2. INITIAL SETUP
# =====================================================================

$ProjectFolder = Join-Path $MigrationRoot $ProjectName
$GitFolder = Join-Path $ProjectFolder "Git"
$ExportFolder = Join-Path $ProjectFolder "Export"
$LogFolder = Join-Path $ProjectFolder "Logs"

New-Item -ItemType Directory -Force -Path $ProjectFolder | Out-Null
New-Item -ItemType Directory -Force -Path $GitFolder | Out-Null
New-Item -ItemType Directory -Force -Path $ExportFolder | Out-Null
New-Item -ItemType Directory -Force -Path $LogFolder | Out-Null

$LogFile = Join-Path $LogFolder "migration.log"
$ReportFile = Join-Path $ProjectFolder "migration-report.csv"

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $Line = "[$Time] [$Level] $Message"

    Write-Host $Line

    Add-Content -Path $LogFile -Value $Line
}

function Invoke-AzCommand {
    param(
        [string[]]$Arguments
    )

    $Output = & az @Arguments 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Log "Azure CLI command failed: $($Arguments -join ' ')" "ERROR"
        Write-Log ($Output -join "`n") "ERROR"
        return $null
    }

    return $Output
}

function Add-Report {
    param(
        [string]$Item,
        [string]$Type,
        [string]$Status,
        [string]$Details = ""
    )

    [PSCustomObject]@{
        Item    = $Item
        Type    = $Type
        Status  = $Status
        Details = $Details
    } | Export-Csv `
        -Path $ReportFile `
        -Append `
        -NoTypeInformation
}

Write-Log "============================================================"
Write-Log "Azure DevOps Project Migration"
Write-Log "============================================================"

Write-Log "Old Organization : $OldOrg"
Write-Log "New Organization : $NewOrg"
Write-Log "Old Project      : $ProjectName"
Write-Log "New Project      : $NewProjectName"
Write-Log "Migration Folder : $ProjectFolder"

if ($DryRun) {
    Write-Log "DRY RUN MODE ENABLED"
    Write-Log "No repositories, projects, pipelines or variable groups will be created."
}

# =====================================================================
# 3. CHECK REQUIRED TOOLS
# =====================================================================

Write-Log "Checking Azure CLI..."

$AzExists = Get-Command az -ErrorAction SilentlyContinue

if (-not $AzExists) {
    Write-Log "Azure CLI is not installed." "ERROR"
    exit 1
}

Write-Log "Azure CLI found."

Write-Log "Checking Git..."

$GitExists = Get-Command git -ErrorAction SilentlyContinue

if (-not $GitExists) {
    Write-Log "Git is not installed." "ERROR"
    exit 1
}

Write-Log "Git found."

# Check Azure DevOps extension
$Extensions = az extension list -o json | ConvertFrom-Json

$DevOpsExtension = $Extensions |
    Where-Object { $_.name -eq "azure-devops" }

if (-not $DevOpsExtension) {

    Write-Log "Azure DevOps CLI extension not found."

    if (-not $DryRun) {
        az extension add --name azure-devops

        if ($LASTEXITCODE -ne 0) {
            Write-Log "Failed to install Azure DevOps CLI extension." "ERROR"
            exit 1
        }
    }
}
else {
    Write-Log "Azure DevOps CLI extension found."
}

# =====================================================================
# 4. VERIFY OLD ORGANIZATION
# =====================================================================

Write-Log "============================================================"
Write-Log "STEP 1 - Verify OLD organization"
Write-Log "============================================================"

$OldProjectJson = az devops project show `
    --organization $OldOrg `
    --project $ProjectName `
    -o json 2>&1

if ($LASTEXITCODE -ne 0) {

    Write-Log "Cannot access old project: $ProjectName" "ERROR"

    Write-Log ""
    Write-Log "Make sure you are logged into the OLD Azure DevOps account."
    Write-Log "Run:"
    Write-Log "az login"

    exit 1
}

$OldProject = $OldProjectJson | ConvertFrom-Json

Write-Log "Old project found: $($OldProject.name)"

$OldProjectJson |
    Out-File (Join-Path $ExportFolder "old-project.json")

Add-Report `
    -Item $ProjectName `
    -Type "Project" `
    -Status "Found" `
    -Details $OldOrg

# =====================================================================
# 5. GET ALL REPOSITORIES
# =====================================================================

Write-Log "============================================================"
Write-Log "STEP 2 - Get repositories"
Write-Log "============================================================"

$ReposJson = az repos list `
    --organization $OldOrg `
    --project $ProjectName `
    -o json

if ($LASTEXITCODE -ne 0) {
    Write-Log "Failed to retrieve repositories." "ERROR"
    exit 1
}

$Repos = $ReposJson | ConvertFrom-Json

$ReposJson |
    Out-File (Join-Path $ExportFolder "repositories.json")

Write-Log "Repositories found: $($Repos.Count)"

foreach ($Repo in $Repos) {
    Write-Log "  Repository: $($Repo.name)"
}

# =====================================================================
# 6. GET PIPELINES
# =====================================================================

Write-Log "============================================================"
Write-Log "STEP 3 - Get pipelines"
Write-Log "============================================================"

$PipelinesJson = az pipelines list `
    --organization $OldOrg `
    --project $ProjectName `
    -o json

if ($LASTEXITCODE -eq 0) {

    $Pipelines = $PipelinesJson | ConvertFrom-Json

    $PipelinesJson |
        Out-File (Join-Path $ExportFolder "pipelines.json")

    Write-Log "Pipelines found: $($Pipelines.Count)"

    foreach ($Pipeline in $Pipelines) {
        Write-Log "  Pipeline: $($Pipeline.name)"
    }

}
else {

    Write-Log "Could not retrieve pipelines." "WARNING"

    $Pipelines = @()
}

# =====================================================================
# 7. GET VARIABLE GROUPS
# =====================================================================

Write-Log "============================================================"
Write-Log "STEP 4 - Get variable groups"
Write-Log "============================================================"

$VariableGroupsJson = az pipelines variable-group list `
    --organization $OldOrg `
    --project $ProjectName `
    -o json

if ($LASTEXITCODE -eq 0) {

    $VariableGroups = $VariableGroupsJson | ConvertFrom-Json

    $VariableGroupsJson |
        Out-File (Join-Path $ExportFolder "variable-groups.json")

    Write-Log "Variable groups found: $($VariableGroups.Count)"

    foreach ($Group in $VariableGroups) {
        Write-Log "  Variable Group: $($Group.name)"
    }

}
else {

    Write-Log "Could not retrieve variable groups." "WARNING"

    $VariableGroups = @()
}

# =====================================================================
# 8. EXPORT SERVICE CONNECTIONS
# =====================================================================

Write-Log "============================================================"
Write-Log "STEP 5 - Export service connections"
Write-Log "============================================================"

$ServiceConnections = az devops invoke `
    --organization $OldOrg `
    --area serviceendpoint `
    --resource endpoints `
    --route-parameters project="$ProjectName" `
    --http-method GET `
    -o json 2>$null

if ($LASTEXITCODE -eq 0) {

    $ServiceConnections |
        Out-File (Join-Path $ExportFolder "service-connections.json")

    Write-Log "Service connections exported."

}
else {

    Write-Log "Could not retrieve service connections." "WARNING"
}

# =====================================================================
# 9. EXPORT ENVIRONMENTS
# =====================================================================

Write-Log "============================================================"
Write-Log "STEP 6 - Export environments"
Write-Log "============================================================"

$Environments = az devops invoke `
    --organization $OldOrg `
    --area environments `
    --resource environments `
    --route-parameters project="$ProjectName" `
    --http-method GET `
    -o json 2>$null

if ($LASTEXITCODE -eq 0) {

    $Environments |
        Out-File (Join-Path $ExportFolder "environments.json")

    Write-Log "Environments exported."

}
else {

    Write-Log "Could not retrieve environments." "WARNING"
}

# =====================================================================
# 10. DRY RUN STOP
# =====================================================================

if ($DryRun) {

    Write-Log "============================================================"
    Write-Log "DRY RUN COMPLETE"
    Write-Log "============================================================"

    Write-Log "Inventory exported to:"
    Write-Log $ExportFolder

    Write-Log ""
    Write-Log "No destination changes were made."

    exit 0
}

# =====================================================================
# 11. VERIFY NEW ORGANIZATION
# =====================================================================

Write-Log "============================================================"
Write-Log "STEP 7 - Verify NEW organization"
Write-Log "============================================================"

$NewProjects = az devops project list `
    --organization $NewOrg `
    -o json 2>&1

if ($LASTEXITCODE -ne 0) {

    Write-Log "Cannot access NEW Azure DevOps organization." "ERROR"

    Write-Log ""
    Write-Log "Make sure you are logged into the NEW Azure DevOps account."
    Write-Log "Run:"
    Write-Log "az login"

    exit 1
}

Write-Log "New organization is accessible."

# =====================================================================
# 12. CREATE DESTINATION PROJECT
# =====================================================================

Write-Log "============================================================"
Write-Log "STEP 8 - Create destination project"
Write-Log "============================================================"

$ExistingNewProject = az devops project show `
    --organization $NewOrg `
    --project $NewProjectName `
    -o json 2>$null

if ($LASTEXITCODE -eq 0) {

    Write-Log "Destination project already exists: $NewProjectName"

}
else {

    Write-Log "Creating destination project: $NewProjectName"

    az devops project create `
        --organization $NewOrg `
        --name $NewProjectName `
        --visibility private

    if ($LASTEXITCODE -ne 0) {

        Write-Log "Failed to create destination project." "ERROR"
        exit 1
    }

    Write-Log "Destination project created."
}

Add-Report `
    -Item $NewProjectName `
    -Type "Project" `
    -Status "Created/Exists" `
    -Details $NewOrg

# =====================================================================
# 13. MIGRATE REPOSITORIES
# =====================================================================

Write-Log "============================================================"
Write-Log "STEP 9 - Migrate Git repositories"
Write-Log "============================================================"

$RepoNumber = 0

foreach ($Repo in $Repos) {

    $RepoNumber++

    $RepoName = $Repo.name

    Write-Log ""
    Write-Log "------------------------------------------------------------"
    Write-Log "Repository $RepoNumber of $($Repos.Count): $RepoName"
    Write-Log "------------------------------------------------------------"

    # ---------------------------------------------------------------
    # Check destination repository
    # ---------------------------------------------------------------

    $ExistingRepo = az repos show `
        --organization $NewOrg `
        --project $NewProjectName `
        --repository $RepoName `
        -o json 2>$null

    if ($LASTEXITCODE -ne 0) {

        Write-Log "Creating destination repository: $RepoName"

        az repos create `
            --organization $NewOrg `
            --project $NewProjectName `
            --name $RepoName `
            -o json

        if ($LASTEXITCODE -ne 0) {

            Write-Log "Failed to create repository: $RepoName" "ERROR"

            Add-Report `
                -Item $RepoName `
                -Type "Repository" `
                -Status "FAILED" `
                -Details "Could not create destination repository"

            continue
        }

    }
    else {

        Write-Log "Destination repository already exists: $RepoName"
    }

    # ---------------------------------------------------------------
    # Get OLD repository URL
    # ---------------------------------------------------------------

    $OldRepoUrl = az repos show `
        --organization $OldOrg `
        --project $ProjectName `
        --repository $RepoName `
        --query remoteUrl `
        -o tsv

    if ($LASTEXITCODE -ne 0) {

        Write-Log "Could not get old repository URL." "ERROR"

        Add-Report `
            -Item $RepoName `
            -Type "Repository" `
            -Status "FAILED" `
            -Details "Could not get old repository URL"

        continue
    }

    # ---------------------------------------------------------------
    # Get NEW repository URL
    # ---------------------------------------------------------------

    $NewRepoUrl = az repos show `
        --organization $NewOrg `
        --project $NewProjectName `
        --repository $RepoName `
        --query remoteUrl `
        -o tsv

    if ($LASTEXITCODE -ne 0) {

        Write-Log "Could not get new repository URL." "ERROR"

        Add-Report `
            -Item $RepoName `
            -Type "Repository" `
            -Status "FAILED" `
            -Details "Could not get new repository URL"

        continue
    }

    Write-Log "Old URL: $OldRepoUrl"
    Write-Log "New URL: $NewRepoUrl"

    # ---------------------------------------------------------------
    # Remove previous temporary mirror if present
    # ---------------------------------------------------------------

    $MirrorFolder = Join-Path $GitFolder "$RepoName.git"

    if (Test-Path $MirrorFolder) {

        Write-Log "Removing previous mirror: $MirrorFolder"

        Remove-Item `
            -Path $MirrorFolder `
            -Recurse `
            -Force
    }

    # ---------------------------------------------------------------
    # Clone OLD repository as mirror
    # ---------------------------------------------------------------

    Write-Log "Cloning repository as mirror..."

    Set-Location $GitFolder

    git clone --mirror $OldRepoUrl "$RepoName.git"

    if ($LASTEXITCODE -ne 0) {

        Write-Log "git clone --mirror failed for $RepoName" "ERROR"

        Add-Report `
            -Item $RepoName `
            -Type "Repository" `
            -Status "FAILED" `
            -Details "git clone --mirror failed"

        continue
    }

    Set-Location $MirrorFolder

    # ---------------------------------------------------------------
    # Change PUSH URL to NEW repository
    # ---------------------------------------------------------------

    git remote set-url --push origin $NewRepoUrl

    if ($LASTEXITCODE -ne 0) {

        Write-Log "Failed to configure destination push URL." "ERROR"

        Set-Location $GitFolder

        continue
    }

    # ---------------------------------------------------------------
    # Push complete mirror
    # ---------------------------------------------------------------

    Write-Log "Pushing complete Git mirror..."

    git push --mirror

    if ($LASTEXITCODE -ne 0) {

        Write-Log "git push --mirror failed for $RepoName" "ERROR"

        Add-Report `
            -Item $RepoName `
            -Type "Repository" `
            -Status "FAILED" `
            -Details "git push --mirror failed"

        Set-Location $GitFolder

        continue
    }

    Write-Log "Repository migration successful: $RepoName"

    Add-Report `
        -Item $RepoName `
        -Type "Repository" `
        -Status "SUCCESS" `
        -Details "Full mirror pushed"

    Set-Location $GitFolder
}

# =====================================================================
# 14. MIGRATE VARIABLE GROUPS
# =====================================================================

Write-Log "============================================================"
Write-Log "STEP 10 - Migrate variable groups"
Write-Log "============================================================"

foreach ($Group in $VariableGroups) {

    $GroupName = $Group.name

    Write-Log ""
    Write-Log "Variable Group: $GroupName"

    # Check destination group
    $ExistingGroup = az pipelines variable-group list `
        --organization $NewOrg `
        --project $NewProjectName `
        --query "[?name=='$GroupName']" `
        -o json | ConvertFrom-Json

    if ($ExistingGroup.Count -gt 0) {

        Write-Log "Variable group already exists: $GroupName"

        $NewGroupId = $ExistingGroup[0].id

    }
    else {

        Write-Log "Creating variable group: $GroupName"

        $NewGroupJson = az pipelines variable-group create `
            --organization $NewOrg `
            --project $NewProjectName `
            --name $GroupName `
            --authorize false `
            -o json

        if ($LASTEXITCODE -ne 0) {

            Write-Log "Failed to create variable group: $GroupName" "ERROR"

            Add-Report `
                -Item $GroupName `
                -Type "VariableGroup" `
                -Status "FAILED" `
                -Details "Could not create group"

            continue
        }

        $NewGroup = $NewGroupJson | ConvertFrom-Json

        $NewGroupId = $NewGroup.id
    }

    # ---------------------------------------------------------------
    # Export variables
    # ---------------------------------------------------------------

    if ($null -ne $Group.variables) {

        foreach ($Property in $Group.variables.PSObject.Properties) {

            $VariableName = $Property.Name
            $Variable = $Property.Value

            # Secret values are intentionally NOT copied.
            if ($Variable.isSecret -eq $true) {

                Write-Log "Secret variable skipped: $VariableName" "WARNING"

                Add-Report `
                    -Item "$GroupName/$VariableName" `
                    -Type "SecretVariable" `
                    -Status "SKIPPED" `
                    -Details "Secret must be recreated manually"

                continue
            }

            $VariableValue = $Variable.value

            Write-Log "Creating variable: $VariableName"

            az pipelines variable-group variable create `
                --organization $NewOrg `
                --project $NewProjectName `
                --group-id $NewGroupId `
                --name $VariableName `
                --value "$VariableValue" `
                -o none

            if ($LASTEXITCODE -eq 0) {

                Add-Report `
                    -Item "$GroupName/$VariableName" `
                    -Type "Variable" `
                    -Status "SUCCESS" `
                    -Details "Non-secret variable"

            }
            else {

                Write-Log "Failed to create variable: $VariableName" "WARNING"

                Add-Report `
                    -Item "$GroupName/$VariableName" `
                    -Type "Variable" `
                    -Status "FAILED" `
                    -Details "Could not create variable"
            }
        }
    }

    Add-Report `
        -Item $GroupName `
        -Type "VariableGroup" `
        -Status "SUCCESS/EXISTS" `
        -Details "Non-secret variables processed"
}

# =====================================================================
# 15. CREATE YAML PIPELINES
# =====================================================================

Write-Log "============================================================"
Write-Log "STEP 11 - Create YAML pipelines"
Write-Log "============================================================"

foreach ($Pipeline in $Pipelines) {

    $PipelineName = $Pipeline.name

    Write-Log ""
    Write-Log "Pipeline: $PipelineName"

    # Some pipeline definitions can contain repository information.
    # We attempt to retrieve the full definition.

    $PipelineDefinition = az pipelines show `
        --organization $OldOrg `
        --project $ProjectName `
        --id $Pipeline.id `
        -o json 2>$null

    if ($LASTEXITCODE -ne 0) {

        Write-Log "Could not retrieve pipeline definition: $PipelineName" "WARNING"

        Add-Report `
            -Item $PipelineName `
            -Type "Pipeline" `
            -Status "MANUAL" `
            -Details "Could not retrieve pipeline definition"

        continue
    }

    $PipelineDefinitionObject = $PipelineDefinition | ConvertFrom-Json

    # Save the original definition
    $PipelineDefinition |
        Out-File "$ExportFolder\pipeline-$($Pipeline.id).json"

    # YAML pipeline information
    $YamlPath = $null
    $RepositoryName = $null
    $BranchName = $null

    if ($PipelineDefinitionObject.configuration) {

        if ($PipelineDefinitionObject.configuration.path) {
            $YamlPath = $PipelineDefinitionObject.configuration.path
        }

        if ($PipelineDefinitionObject.repository) {

            $RepositoryName =
                $PipelineDefinitionObject.repository.name

            $BranchName =
                $PipelineDefinitionObject.repository.defaultBranch
        }
    }

    if (-not $RepositoryName) {

        Write-Log "Repository could not be determined for pipeline: $PipelineName" "WARNING"

        Add-Report `
            -Item $PipelineName `
            -Type "Pipeline" `
            -Status "MANUAL" `
            -Details "Repository information unavailable"

        continue
    }

    if (-not $YamlPath) {

        $YamlPath = "azure-pipelines.yml"
    }

    if (-not $BranchName) {

        $BranchName = "refs/heads/main"
    }

    # Convert refs/heads/main to main
    if ($BranchName.StartsWith("refs/heads/")) {
        $BranchName = $BranchName.Substring(11)
    }

    Write-Log "Repository : $RepositoryName"
    Write-Log "Branch     : $BranchName"
    Write-Log "YAML       : $YamlPath"

    # Check whether pipeline already exists
    $ExistingPipeline = az pipelines list `
        --organization $NewOrg `
        --project $NewProjectName `
        --query "[?name=='$PipelineName']" `
        -o json | ConvertFrom-Json

    if ($ExistingPipeline.Count -gt 0) {

        Write-Log "Pipeline already exists: $PipelineName"

        Add-Report `
            -Item $PipelineName `
            -Type "Pipeline" `
            -Status "EXISTS" `
            -Details "Destination pipeline already exists"

        continue
    }

    Write-Log "Creating YAML pipeline: $PipelineName"

    az pipelines create `
        --organization $NewOrg `
        --project $NewProjectName `
        --name $PipelineName `
        --repository $RepositoryName `
        --branch $BranchName `
        --yml-path $YamlPath `
        -o none

    if ($LASTEXITCODE -eq 0) {

        Write-Log "Pipeline created: $PipelineName"

        Add-Report `
            -Item $PipelineName `
            -Type "Pipeline" `
            -Status "SUCCESS" `
            -Details "YAML pipeline created"

    }
    else {

        Write-Log "Pipeline could not be automatically created." "WARNING"

        Add-Report `
            -Item $PipelineName `
            -Type "Pipeline" `
            -Status "MANUAL" `
            -Details "Review pipeline definition and recreate manually"
    }
}

# =====================================================================
# 16. FINAL INVENTORY OF DESTINATION
# =====================================================================

Write-Log "============================================================"
Write-Log "STEP 12 - Validate destination"
Write-Log "============================================================"

$NewRepos = az repos list `
    --organization $NewOrg `
    --project $NewProjectName `
    -o json | ConvertFrom-Json

$NewPipelines = az pipelines list `
    --organization $NewOrg `
    --project $NewProjectName `
    -o json | ConvertFrom-Json

$NewVariableGroups = az pipelines variable-group list `
    --organization $NewOrg `
    --project $NewProjectName `
    -o json | ConvertFrom-Json

Write-Log "============================================================"
Write-Log "MIGRATION SUMMARY"
Write-Log "============================================================"

Write-Log "Old repository count : $($Repos.Count)"
Write-Log "New repository count : $($NewRepos.Count)"

Write-Log "Old pipeline count   : $($Pipelines.Count)"
Write-Log "New pipeline count   : $($NewPipelines.Count)"

Write-Log "Old variable groups  : $($VariableGroups.Count)"
Write-Log "New variable groups  : $($NewVariableGroups.Count)"

# =====================================================================
# 17. EXPORT DESTINATION INVENTORY
# =====================================================================

$NewRepos |
    ConvertTo-Json -Depth 20 |
    Out-File "$ExportFolder\new-repositories.json"

$NewPipelines |
    ConvertTo-Json -Depth 20 |
    Out-File "$ExportFolder\new-pipelines.json"

$NewVariableGroups |
    ConvertTo-Json -Depth 20 |
    Out-File "$ExportFolder\new-variable-groups.json"

# =====================================================================
# 18. FINAL MESSAGE
# =====================================================================

Write-Log ""
Write-Log "============================================================"
Write-Log "MIGRATION PROCESS FINISHED"
Write-Log "============================================================"

Write-Log ""
Write-Log "Migration folder:"
Write-Log $ProjectFolder

Write-Log ""
Write-Log "Migration report:"
Write-Log $ReportFile

Write-Log ""
Write-Log "Review the following manually:"
Write-Log "  1. Secret variable values"
Write-Log "  2. Service connections"
Write-Log "  3. Service connection permissions"
Write-Log "  4. Environments"
Write-Log "  5. Environment approvals/checks"
Write-Log "  6. Branch policies"
Write-Log "  7. Repository permissions"
Write-Log "  8. Pipeline permissions"
Write-Log "  9. Azure subscriptions / identities"
Write-Log " 10. Work items / Boards"
Write-Log " 11. Classic pipelines, if any"
Write-Log ""
Write-Log "DO NOT delete the old project until the new project has"
Write-Log "been completely validated."
Write-Log ""
Write-Log "============================================================"
```

## How to use it

Save the script as:

```text
C:\AzureDevOpsMigration\Migrate-AzureDevOpsProject.ps1
```

Then **only change these three lines**:

```powershell
$OldOrg = "https://dev.azure.com/OLD_ORGANIZATION"
$NewOrg = "https://dev.azure.com/NEW_ORGANIZATION"

$ProjectName = "YOUR_PROJECT_NAME"
```

For example, eventually:

```powershell
$OldOrg = "https://dev.azure.com/projectterrier"
$NewOrg = "https://dev.azure.com/acionix"

$ProjectName = "YourProject"
```

### First run — inventory only

Run:

```powershell
.\Migrate-AzureDevOpsProject.ps1 -DryRun
```

This **does not create or modify anything** in the destination. It creates:

```text
C:\AzureDevOpsMigration\YourProject\
│
├── Export\
│   ├── old-project.json
│   ├── repositories.json
│   ├── pipelines.json
│   ├── variable-groups.json
│   ├── service-connections.json
│   ├── environments.json
│   └── ...
│
├── Git\
│
├── Logs\
│   └── migration.log
│
└── migration-report.csv
```

Review that first.

### Actual migration

After the dry run looks correct:

```powershell
.\Migrate-AzureDevOpsProject.ps1
```

The script will then:

```text
OLD ORGANIZATION
       │
       ├── Project
       ├── Repositories ───────────────┐
       ├── Pipelines                   │
       ├── Variable Groups             │
       ├── Service Connections         │
       └── Environments                │
                                      │
                                      ▼
                         NEW ORGANIZATION
                                      │
                         ┌────────────┴────────────┐
                         │                         │
                    Git migration          Azure DevOps config
                         │                         │
                   --mirror                 recreate
                         │
                         ▼
                    Full history
                    Branches
                    Tags
```

### One important limitation

I deliberately **do not automatically copy service-connection credentials, secret variables, approvals, branch policies, permissions, or work items**. Those are the parts where blindly copying JSON can either expose credentials or create incorrect security configuration.

The script exports the service connections/environments so you have an inventory of what needs to be recreated.

Also, **test the migration with a project/repository copy before treating the script as your final production migration tool**. In particular, YAML pipeline definitions can vary depending on whether they use Git repos, GitHub, repository resources, templates, classic pipelines, or custom configuration.

After the migration, compare:

```powershell
# Repository count
az repos list --organization $OldOrg --project $ProjectName --query "length(@)" -o tsv

az repos list --organization $NewOrg --project $NewProjectName --query "length(@)" -o tsv

# Pipeline count
az pipelines list --organization $OldOrg --project $ProjectName --query "length(@)" -o tsv

az pipelines list --organization $NewOrg --project $NewProjectName --query "length(@)" -o tsv

# Variable group count
az pipelines variable-group list --organization $OldOrg --project $ProjectName --query "length(@)" -o tsv

az pipelines variable-group list --organization $NewOrg --project $NewProjectName --query "length(@)" -o tsv
```

The **old and new repository counts should match**, and you should run the important CI/CD pipelines in the new organization before retiring the old project.
