#Requires -Version 5.1
<#
.SYNOPSIS
    Environment File Generator - PowerShell Version

.DESCRIPTION
    Generates .env files from Azure Key Vault secrets for various applications and environments.

.PARAMETER App
    Application name (my-web-app)

.PARAMETER Environment
    Environment name (dev, staging, prod)

.PARAMETER OutputFile
    Output file path (default: .\.env)

.PARAMETER DryRun
    Show what would be generated without creating the file

.PARAMETER ListApps
    List available applications and environments

.PARAMETER Verbose
    Enable verbose output

.PARAMETER Interactive
    Run in interactive mode (default if no parameters specified)

.EXAMPLE
    .\generate-env.ps1
    Run in interactive mode

.EXAMPLE
    .\generate-env.ps1 -App my-web-app -Environment dev
    Generate .env file for my-web-app dev environment

.EXAMPLE
    .\generate-env.ps1 -App my-web-app -Environment prod -OutputFile .\prod.env
    Generate prod environment file with custom output path

.EXAMPLE
    .\generate-env.ps1 -ListApps
    Show available applications and environments

.EXAMPLE
    .\generate-env.ps1 -App my-web-app -Environment dev -DryRun
    Preview what would be generated without creating file

.NOTES
    Requirements:
    - Azure PowerShell module (Az)
    - PowerShell 5.1 or later
    - Access to the application secrets Key Vault
    - Azure authentication (will prompt automatically if not logged in)
#>

[CmdletBinding()]
param(
    [Parameter(HelpMessage="Application name")]
    [string]$App,

    [Parameter(HelpMessage="Environment name")]
    [string]$Environment,

    [Parameter(HelpMessage="Output file path")]
    [string]$OutputFile = ".\.env",

    [Parameter(HelpMessage="Show what would be generated without creating file")]
    [switch]$DryRun,

    [Parameter(HelpMessage="List available applications and environments")]
    [switch]$ListApps,

    [Parameter(HelpMessage="Enable verbose output")]
    [switch]$VerboseOutput,

    [Parameter(HelpMessage="Run in interactive mode")]
    [switch]$Interactive
)

# =============================================================================
# INITIALIZATION
# =============================================================================

# Set error action preference
$ErrorActionPreference = "Stop"

# Script paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $ScriptDir "app-configs.json"

# Global variables
$Script:VaultName = ""
$Script:Config = $null

# Colors for console output
$Colors = @{
    Info    = "Blue"
    Success = "Green"
    Warning = "Yellow"
    Error   = "Red"
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level
    )

    $timestamp = Get-Date -Format "HH:mm:ss"
    $prefix = "[$Level]".ToUpper()

    Write-Host "[$timestamp] " -NoNewline -ForegroundColor Gray
    Write-Host $prefix -NoNewline -ForegroundColor $Colors[$Level]
    Write-Host " $Message" -ForegroundColor $Colors[$Level]
}

function Test-Dependencies {
    Write-Log -Message "Checking dependencies..." -Level Info

    # Dynamically detect user's Documents folder and add module paths if they exist
    $documentsPath = [System.Environment]::GetFolderPath('MyDocuments')
    $additionalPaths = @(
        [System.IO.Path]::Combine($documentsPath, 'WindowsPowerShell', 'Modules'),  # Windows PowerShell 5.1
        [System.IO.Path]::Combine($documentsPath, 'PowerShell', 'Modules')         # PowerShell 7+
    )

    $currentPaths = $env:PSModulePath -split ';'
    $pathsAdded = $false

    foreach ($path in $additionalPaths) {
        if ((Test-Path $path) -and ($currentPaths -notcontains $path)) {
            $env:PSModulePath += ";$path"
            Write-Log -Message "Added module path: $path" -Level Info
            $pathsAdded = $true
        }
    }

    if ($pathsAdded) {
        Write-Log -Message "Refreshing module cache..." -Level Info
    }

    # Check for Az PowerShell modules with more detailed diagnostics
    $azModules = Get-Module -Name Az* -ListAvailable
    if ($azModules) {
        Write-Log -Message "Found Az modules: $($azModules.Name -join ', ')" -Level Info
    } else {
        Write-Log -Message "No Az modules found at all." -Level Warning
    }

    # Check specifically for Az.KeyVault
    $azKeyVault = Get-Module -Name Az.KeyVault -ListAvailable
    if (-not $azKeyVault) {
        Write-Log -Message "Azure PowerShell module (Az.KeyVault) not found." -Level Error
        Write-Log -Message "Install with one of these commands:" -Level Info
        Write-Log -Message "  Option 1: Install-Module -Name Az -Scope CurrentUser" -Level Info
        Write-Log -Message "  Option 2: Install-Module -Name Az.KeyVault -Scope CurrentUser" -Level Info
        Write-Log -Message "Then restart PowerShell and try again." -Level Info
        throw "Missing dependency: Az.KeyVault PowerShell module"
    } else {
        Write-Log -Message "Az.KeyVault module found: version $($azKeyVault.Version)" -Level Info
    }

    # Try to import the module
    try {
        Import-Module Az.KeyVault -Force
        Write-Log -Message "Az.KeyVault module imported successfully" -Level Info
    }
    catch {
        Write-Log -Message "Failed to import Az.KeyVault module: $($_.Exception.Message)" -Level Error
        throw "Failed to import Az.KeyVault module"
    }

    # Check Azure authentication
    try {
        $context = Get-AzContext
        if (-not $context) {
            Write-Log -Message "Not authenticated to Azure. Attempting to authenticate..." -Level Warning
            try {
                # Attempt interactive authentication
                $context = Connect-AzAccount -ErrorAction Stop
                Write-Log -Message "Azure authentication successful: $($context.Context.Account.Id)" -Level Success
            }
            catch {
                Write-Log -Message "Azure authentication failed: $($_.Exception.Message)" -Level Error
                Write-Log -Message "Please run Connect-AzAccount manually if automatic authentication fails." -Level Info
                throw "Azure authentication required"
            }
        } else {
            Write-Log -Message "Azure context: $($context.Account.Id)" -Level Info
        }
    }
    catch {
        Write-Log -Message "Azure authentication check failed: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Get-VaultName {
    Write-Log -Message "Getting Key Vault name from configuration..." -Level Info

    try {
        # Get vault name from config file
        $Script:VaultName = $Script:Config.vault_name

        if ([string]::IsNullOrWhiteSpace($Script:VaultName)) {
            Write-Log -Message "Could not get vault_name from configuration file: $ConfigFile" -Level Error
            throw "Vault name not found in configuration"
        }

        Write-Log -Message "Found Key Vault: $($Script:VaultName)" -Level Info
    }
    catch {
        Write-Log -Message "Failed to get vault name: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Get-ConfigurationData {
    if (-not (Test-Path $ConfigFile)) {
        Write-Log -Message "Configuration file not found: $ConfigFile" -Level Error
        throw "Configuration file missing"
    }

    try {
        $Script:Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        Write-Log -Message "Configuration loaded successfully" -Level Info
    }
    catch {
        Write-Log -Message "Failed to parse configuration file: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Show-AvailableApplications {
    Write-Log -Message "Available applications and environments:" -Level Info
    Write-Host ""

    foreach ($appKv in $Script:Config.applications.PSObject.Properties) {
        $appName = $appKv.Name
        $appInfo = $appKv.Value

        Write-Host "  $appName " -ForegroundColor Cyan -NoNewline
        Write-Host "($($appInfo.description)):" -ForegroundColor Gray
        Write-Host "    Environments: " -ForegroundColor Gray -NoNewline
        Write-Host ($appInfo.environments -join ", ") -ForegroundColor White
        Write-Host "    Secrets: " -ForegroundColor Gray -NoNewline
        Write-Host "$($appInfo.secrets.Count) configured" -ForegroundColor White
        Write-Host ""
    }
}

function Test-AppEnvironmentValid {
    param(
        [string]$AppName,
        [string]$EnvName
    )

    # Check if app exists
    $app = $Script:Config.applications.PSObject.Properties | Where-Object { $_.Name -eq $AppName }
    if (-not $app) {
        $availableApps = $Script:Config.applications.PSObject.Properties.Name -join ", "
        Write-Log -Message "Application '$AppName' not found in configuration." -Level Error
        Write-Log -Message "Available applications: $availableApps" -Level Info
        throw "Invalid application name"
    }

    # Check if environment exists for this app
    if ($app.Value.environments -notcontains $EnvName) {
        $availableEnvs = $app.Value.environments -join ", "
        Write-Log -Message "Environment '$EnvName' not available for application '$AppName'." -Level Error
        Write-Log -Message "Available environments for $AppName`: $availableEnvs" -Level Info
        throw "Invalid environment name"
    }

    return $true
}

function Invoke-InteractiveMode {
    Write-Log -Message "Interactive Environment File Generator" -Level Info
    Write-Host ""

    # Show available applications
    Write-Host "Available applications:" -ForegroundColor Yellow
    foreach ($appKv in $Script:Config.applications.PSObject.Properties) {
        Write-Host "  $($appKv.Name) - $($appKv.Value.description)" -ForegroundColor Cyan
    }
    Write-Host ""

    # Get application
    do {
        $selectedApp = Read-Host "Enter application name"
        $app = $Script:Config.applications.PSObject.Properties | Where-Object { $_.Name -eq $selectedApp }
        if (-not $app) {
            Write-Log -Message "Invalid application. Please try again." -Level Error
        }
    } while (-not $app)

    # Show available environments for selected app
    Write-Host ""
    Write-Host "Available environments for $selectedApp`:" -ForegroundColor Yellow
    foreach ($env in $app.Value.environments) {
        Write-Host "  $env" -ForegroundColor Cyan
    }
    Write-Host ""

    # Get environment
    do {
        $selectedEnv = Read-Host "Enter environment"
        if ($app.Value.environments -notcontains $selectedEnv) {
            Write-Log -Message "Invalid environment. Please try again." -Level Error
        }
    } while ($app.Value.environments -notcontains $selectedEnv)

    # Get output file
    Write-Host ""
    $outputPath = Read-Host "Output file path (default: .\.env)"
    if ([string]::IsNullOrWhiteSpace($outputPath)) {
        $outputPath = ".\.env"
    }

    return @{
        App = $selectedApp
        Environment = $selectedEnv
        OutputFile = $outputPath
    }
}

function Get-SecretFromVault {
    param(
        [string]$SecretName,
        [string]$VaultName
    )

    if ($VerboseOutput) {
        Write-Log -Message "Fetching secret: $SecretName" -Level Info
    }

    try {
        $secret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -ErrorAction Stop
        if ($secret) {
            # PowerShell 5.1 compatible method to convert SecureString to plain text
            $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret.SecretValue)
            try {
                return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
            }
            finally {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
            }
        }
    }
    catch {
        $errorMessage = $_.Exception.Message

        # Check for network access errors
        if ($errorMessage -match "ForbiddenByFirewall|network access|blocked by firewall") {
            Write-Log -Message "Network access denied to Key Vault. Ensure you have network access to the vault." -Level Error
            Write-Log -Message "Key Vault requires VPN connection or access from approved IP ranges." -Level Info
            Write-Log -Message "Check your Key Vault's firewall settings and ensure your IP is allowed." -Level Info
            throw "Network access required to access Key Vault"
        }
        elseif ($errorMessage -match "SecretNotFound|not found") {
            # Secret doesn't exist, this is handled by caller
            return $null
        }
        else {
            # Other error, show if verbose
            if ($VerboseOutput) {
                Write-Log -Message "Could not retrieve secret '$SecretName': $errorMessage" -Level Warning
            }
            return $null
        }
    }

    return $null
}

function New-EnvironmentContent {
    param(
        [string]$AppName,
        [string]$EnvName
    )

    Write-Log -Message "Generating .env content for $AppName ($EnvName environment)..." -Level Info

    $app = $Script:Config.applications.$AppName
    $content = @()
    $missingSecrets = @()
    $foundSecrets = 0
    $totalSecrets = $app.secrets.Count

    # Add header
    $content += "# ============================================================================="
    $content += "# Environment Variables for $AppName ($EnvName environment)"
    $content += "# Generated on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $content += "# Key Vault: $($Script:VaultName)"
    $content += "# ============================================================================="
    $content += ""

    # Group secrets by category
    $secretsByCategory = $app.secrets | Group-Object -Property category

    foreach ($categoryGroup in $secretsByCategory) {
        $categoryName = $categoryGroup.Name.ToUpper()
        $content += ""
        $content += "# $categoryName"

        foreach ($secret in $categoryGroup.Group) {
            # Build secret name using naming convention
            $secretName = "$AppName-$EnvName-$($secret.vault_key)"

            # Get secret value from vault
            $secretValue = Get-SecretFromVault -SecretName $secretName -VaultName $Script:VaultName

            if ($secretValue) {
                $content += "$($secret.env_var)=$secretValue"
                $foundSecrets++
                if ($VerboseOutput) {
                    Write-Log -Message "Found: $($secret.env_var)" -Level Success
                }
            }
            else {
                $content += "$($secret.env_var)="
                $missingSecrets += $secretName
                if ($VerboseOutput) {
                    Write-Log -Message "Missing: $($secret.env_var) (vault key: $secretName)" -Level Warning
                }
            }
        }
    }

    # Show summary
    Write-Log -Message "Secrets summary: $foundSecrets/$totalSecrets found" -Level Info

    if ($missingSecrets.Count -gt 0) {
        Write-Log -Message "Missing secrets in Key Vault:" -Level Warning
        foreach ($missingSecret in $missingSecrets) {
            Write-Host "  - $missingSecret" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Log -Message "To add missing secrets, use:" -Level Info
        Write-Log -Message "Set-AzKeyVaultSecret -VaultName `"$($Script:VaultName)`" -Name `"SECRET_NAME`" -SecretValue (ConvertTo-SecureString `"SECRET_VALUE`" -AsPlainText -Force)" -Level Info
    }

    return $content
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

function Invoke-Main {
    try {
        # Handle ListApps parameter first
        if ($ListApps) {
            Get-ConfigurationData
            Show-AvailableApplications
            return
        }

        # Check dependencies
        Test-Dependencies

        # Load configuration
        Get-ConfigurationData

        # Get Key Vault name
        Get-VaultName

        # Determine if interactive mode needed
        $needInteractive = $Interactive -or ([string]::IsNullOrWhiteSpace($App) -or [string]::IsNullOrWhiteSpace($Environment))

        if ($needInteractive) {
            $interactiveResult = Invoke-InteractiveMode
            $App = $interactiveResult.App
            $Environment = $interactiveResult.Environment
            $OutputFile = $interactiveResult.OutputFile
        }

        # Validate app and environment
        Test-AppEnvironmentValid -AppName $App -EnvName $Environment

        # Generate content
        $envContent = New-EnvironmentContent -AppName $App -EnvName $Environment

        if ($DryRun) {
            Write-Log -Message "DRY RUN - Content that would be written to $OutputFile`:" -Level Info
            Write-Host "----------------------------------------" -ForegroundColor Gray
            $envContent | ForEach-Object { Write-Host $_ }
            Write-Host "----------------------------------------" -ForegroundColor Gray
        }
        else {
            # Write to file
            $envContent | Out-File -FilePath $OutputFile -Encoding UTF8
            Write-Log -Message "Environment file generated: $OutputFile" -Level Success

            # Show file info
            $fileInfo = Get-Item $OutputFile
            $lineCount = (Get-Content $OutputFile).Count
            Write-Log -Message "File contains $lineCount lines ($($fileInfo.Length) bytes)" -Level Info
        }
    }
    catch {
        Write-Log -Message "Script execution failed: $($_.Exception.Message)" -Level Error
        if ($VerboseOutput) {
            Write-Host $_.Exception.StackTrace -ForegroundColor Red
        }
        exit 1
    }
}

# Execute main function
Invoke-Main