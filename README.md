# Environment File Generator

Automated .env file generation from Azure Key Vault secrets for your organization's applications.

## Overview

This toolkit provides bash and PowerShell scripts to generate `.env` files from Azure Key Vault secrets, plus a Python script to upload secrets from existing `.env` files to the vault. The scripts are designed to stay in sync and support multiple applications and environments.

## Quick Start for Organizations

1. **Set up Azure Key Vault**: Create an Azure Key Vault for your organization
2. **Configure access**: Set up appropriate access policies and network restrictions
3. **Customize configuration**: Update `app-configs.json` with your applications and secrets
4. **Upload existing secrets**: Use `upload-secrets.py` to migrate from existing `.env` files
5. **Generate environment files**: Use the bash/PowerShell scripts to create `.env` files

## Architecture

### Key Vault Structure
- **Vault Name**: `kv-my-org-secrets` (configure in `app-configs.json`)
- **Secret Naming Convention**: `{app}-{env}-{vault-key}`
  - Example: `my-web-app-dev-db-password`
  - **Azure Compliance**: Secret names are 1-127 characters, using only alphanumeric characters and dashes

### Supported Applications
- **my-web-app**: Main web application (dev, staging, prod)
- **api-service**: Backend API microservice (dev, staging, prod)
- **worker-service**: Background job processor (dev, staging, prod)

## Prerequisites

### For Bash Script (`generate-env.sh`)
- Azure CLI (`az`) installed and authenticated
- `jq` command-line JSON processor
- Bash 4.0+ (Linux, macOS, WSL, Git Bash)

### For PowerShell Script (`generate-env.ps1`)
- PowerShell 5.1 or later
- Azure PowerShell module (`Az.KeyVault`)
- Windows PowerShell or PowerShell Core

### For Python Upload Script (`upload-secrets.py`)
- Python 3.7 or later
- Azure SDK packages (see `requirements.txt`)
- Install with: `pip install -r requirements.txt`

### Common Requirements
- **Network access** to Azure Key Vault (VPN or approved network ranges)
- User access to the Key Vault with appropriate permissions

### Network Security
- Configure your Key Vault with appropriate network restrictions
- **Access methods**:
  1. **VPN connection**: Connect through your organization's VPN for external access
  2. **Azure VM access**: VMs in approved subnets can access using authenticated users or managed identities
  3. **Local development**: Configure firewall rules to allow developer IP ranges
- **Recommended setup**: Use Azure Private Endpoints or Service Endpoints for production environments

## Installation

### Azure CLI (for bash script)
```bash
# Install Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Install jq
sudo apt-get install jq  # Ubuntu/Debian
brew install jq          # macOS
```

### Azure PowerShell (for PowerShell script)
```powershell
# Install Azure PowerShell module
Install-Module -Name Az -Scope CurrentUser -Force
```

### Python Dependencies (for upload script)
```bash
# Install Python dependencies
pip install -r requirements.txt

# Or install individually
pip install azure-keyvault-secrets azure-identity python-dotenv
```

### Network Configuration

**IMPORTANT**: Configure network access for your Key Vault:

1. Update the vault name in `app-configs.json` to match your Key Vault
2. Configure your Key Vault's network settings:
   - Add your organization's IP ranges to firewall rules
   - Set up VPN routing if using a corporate VPN
   - Consider using Azure Private Endpoints for enhanced security

### Authentication

**For external users (via NetBird VPN):**
```bash
# Bash (required)
az login

# PowerShell (optional - will prompt automatically if needed)
Connect-AzAccount
```

**For Azure VMs (using user credentials or managed identity):**
```bash
# Option 1: Use your user credentials (recommended for most VMs)
az login

# Option 2: Use managed identity (GitHub runners only have explicit policies)
az login --identity

# PowerShell equivalents (will prompt automatically if needed)
Connect-AzAccount
Connect-AzAccount -Identity
```

## Typical Workflow

### 1. Upload Secrets
If you have existing .env files, upload them to the Key Vault:

```bash
# Upload dev environment secrets
python upload-secrets.py --env-file .env.dev --environment dev --app my-web-app

# Upload production environment secrets
python upload-secrets.py --env-file .env.prod --environment prod --app my-web-app
```

### 2. Generate .env Files
Generate .env files from Key Vault secrets:

```bash
# Generate dev environment file
./generate-env.sh --app my-web-app --env dev

# Generate production environment file
./generate-env.ps1 -App my-web-app -Environment prod
```

### 3. Validate Upload Success
Verify that secrets were uploaded correctly:

```bash
# Quick validation - list all secrets
az keyvault secret list --vault-name kv-my-org-secrets --output table

# Or use dry-run mode to see if download would work
./generate-env.sh --app my-web-app --env dev --dry-run
```

## Usage

### Interactive Mode

**Bash:**
```bash
./generate-env.sh
```

**PowerShell:**
```powershell
.\generate-env.ps1
```

### Command Line Mode

**Bash:**
```bash
# Basic usage
./generate-env.sh --app my-web-app --env dev

# Custom output file
./generate-env.sh --app my-web-app --env prod --output ./production.env

# Dry run (preview without creating file)
./generate-env.sh --app my-web-app --env dev --dry-run

# List available applications
./generate-env.sh --list-apps

# Verbose output
./generate-env.sh --app my-web-app --env dev --verbose
```

**PowerShell:**

*Note: You may need to allow script execution first:*
```powershell
# Allow scripts for current session
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
```

```powershell
# Basic usage
.\generate-env.ps1 -App my-web-app -Environment dev

# Custom output file
.\generate-env.ps1 -App my-web-app -Environment prod -OutputFile .\production.env

# Dry run (preview without creating file)
.\generate-env.ps1 -App my-web-app -Environment dev -DryRun

# List available applications
.\generate-env.ps1 -ListApps

# Verbose output
.\generate-env.ps1 -App my-web-app -Environment dev -VerboseOutput
```

### Running from Azure VMs

Azure VMs in approved subnets can run the scripts using user credentials:

**Bash:**
```bash
# On Azure VM - login with user credentials (recommended)
az login

# Generate .env file (same commands as above)
./generate-env.sh --app my-web-app --env dev
```

**PowerShell:**
```powershell
# On Azure VM - login with user credentials (recommended)
Connect-AzAccount

# Generate .env file (same commands as above)
.\generate-env.ps1 -App my-web-app -Environment dev
```

## Configuration

### Adding New Applications

To add new applications, edit `app-configs.json` and add them to the applications object. Each application should specify:
- **description**: Human-readable description
- **environments**: Array of supported environments (e.g., `["dev", "staging", "prod"]`)
- **secrets**: Array of secret definitions with `env_var`, `vault_key`, `category`, and `description`

### Adding New Secrets

Add secrets to the `secrets` array for an existing application:

```json
{
  "env_var": "NEW_API_KEY",
  "vault_key": "new-api-key",
  "category": "external",
  "description": "API key for external service"
}
```

## Secret Management

### Adding Secrets to Key Vault

**Azure CLI:**
```bash
az keyvault secret set \
  --vault-name "kv-my-org-secrets" \
  --name "my-web-app-dev-db-password" \
  --value "your_secret_value"
```

**PowerShell:**
```powershell
Set-AzKeyVaultSecret `
  -VaultName "kv-my-org-secrets" `
  -Name "my-web-app-dev-db-password" `
  -SecretValue (ConvertTo-SecureString "your_secret_value" -AsPlainText -Force)
```

### Bulk Secret Import from .env Files

#### Python Script (Recommended)

The easiest way to upload secrets from an existing .env file:

**Installation:**
```bash
pip install -r requirements.txt
```

**Usage:**
```bash
# Dry run (preview what would be uploaded)
python upload-secrets.py --env-file .env --environment dev --dry-run

# Upload secrets for dev environment
python upload-secrets.py --env-file .env --environment dev

# Upload secrets for production environment
python upload-secrets.py --env-file prod.env --environment prod
```

The script will:
- Read your .env file
- Map environment variables to the correct Key Vault secret names
- Upload all secrets with proper naming convention
- Show a summary of uploaded/failed secrets

#### Manual Commands

For importing multiple secrets manually, you can use these helper commands:

**Bash:**
```bash
# Import from existing .env file (replace APP and ENV with your values)
while IFS='=' read -r key value; do
  if [[ ! -z "$key" && ! "$key" =~ ^# ]]; then
    az keyvault secret set \
      --vault-name "kv-my-org-secrets" \
      --name "my-web-app-dev-$(echo $key | tr '[:upper:]' '[:lower:]' | tr '_' '-')" \
      --value "$value"
  fi
done < .env
```

## Troubleshooting

### Common Issues

1. **"Not logged into Azure"**
   - Run `az login` (bash) or `Connect-AzAccount` (PowerShell)

2. **"PowerShell script cannot be loaded" or "not digitally signed"**
   - Run: `Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process`
   - This allows unsigned scripts for the current PowerShell session only
   - Alternative: `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser` (permanent)

3. **"Network access denied" or "ForbiddenByFirewall"**
   - **Most common issue**: Ensure you're connected to your organization's VPN or within approved network ranges
   - **Check network routing**: Verify Key Vault hostname is accessible from your current location
   - Check your Key Vault's firewall settings in the Azure portal
   - Verify your IP address is in the allowed ranges

4. **"Key Vault name not found"**
   - Check that the vault_name is correctly configured in app-configs.json
   - Ensure the Key Vault exists and you have access permissions
   - Verify the vault name matches your organization's naming convention

5. **"Missing secrets in Key Vault"**
   - Use the secret management commands above to add missing secrets
   - Check secret naming follows the convention: `{app}-{env}-{vault-key}`

6. **"Permission denied on Key Vault"**
   - Ensure your user has "Key Vault Secrets User" role on the vault
   - Check with: `az role assignment list --scope /subscriptions/.../resourceGroups/.../providers/Microsoft.KeyVault/vaults/...`

7. **Python upload script shows success but secrets not visible**
   - Network access restrictions may prevent manual verification through different access paths
   - Verify upload success by running the bash/PowerShell download scripts
   - Or check with: `az keyvault secret list --vault-name kv-my-org-secrets --output table`

### Verbose Mode

Enable verbose mode to see detailed secret fetching information:

**Bash:**
```bash
./generate-env.sh --app my-web-app --env dev --verbose
```

**PowerShell:**
```powershell
.\generate-env.ps1 -App my-web-app -Environment dev -VerboseOutput
```

## Development

### Testing Changes

Use dry-run mode to test configuration changes:

```bash
./generate-env.sh --app my-web-app --env dev --dry-run
```

### Script Synchronization

Both scripts are designed to produce identical output. When modifying one script, ensure the other is updated accordingly:

1. Secret naming convention must match
2. Configuration file format must be identical
3. Output format should be consistent

## Organizational Setup

### Setting Up for Your Organization

1. **Create Azure Key Vault**:
   ```bash
   # Replace with your organization's naming convention
   az keyvault create --name "kv-myorg-secrets" --resource-group "myorg-rg" --location "eastus"
   ```

2. **Configure Access Policies**:
   ```bash
   # Grant developers access to secrets
   az keyvault set-policy --name "kv-myorg-secrets" --upn "developer@myorg.com" --secret-permissions get list

   # Grant service principals access for CI/CD
   az keyvault set-policy --name "kv-myorg-secrets" --spn "app-service-principal-id" --secret-permissions get list
   ```

3. **Update Configuration**:
   - Edit `app-configs.json` to match your applications
   - Change `vault_name` to your Key Vault name
   - Add your applications with their secrets definitions

4. **Network Security** (Recommended):
   ```bash
   # Restrict network access (replace with your IP ranges)
   az keyvault network-rule add --name "kv-myorg-secrets" --ip-address "x.x.x.0/24"
   ```

### Customizing for Your Applications

Example `app-configs.json` structure:
```json
{
  "vault_name": "kv-myorg-secrets",
  "applications": {
    "your-app-name": {
      "description": "Your application description",
      "environments": ["dev", "staging", "prod"],
      "secrets": [
        {
          "env_var": "DATABASE_URL",
          "vault_key": "database-url",
          "category": "database",
          "description": "Primary database connection"
        }
      ]
    }
  }
}
```

## Support

For issues or questions:

1. Check the troubleshooting section above
2. Review the verbose output for detailed error information
3. Ensure all prerequisites are installed and configured
4. Verify the vault name in app-configs.json matches your organization's Key Vault

## File Structure

```
scripts/env-generator/
├── generate-env.sh          # Bash version (download secrets)
├── generate-env.ps1         # PowerShell version (download secrets)
├── upload-secrets.py        # Python script (upload secrets from .env)
├── app-configs.json         # Application configuration
├── requirements.txt         # Python dependencies
└── README.md                # This file
```
