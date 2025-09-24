#!/bin/bash

# =============================================================================
# Environment File Generator - Bash Version
# =============================================================================
# Generates .env files from Azure Key Vault secrets
#
# Usage:
#   ./generate-env.sh                              # Interactive mode
#   ./generate-env.sh --app my-web-app --env dev
#   ./generate-env.sh --app my-web-app --env dev --output /path/to/.env
#   ./generate-env.sh --list-apps
#   ./generate-env.sh --dry-run --app my-web-app --env dev
#
# Requirements:
#   - Azure CLI (az) installed and logged in
#   - jq for JSON processing
#   - Access to the application secrets Key Vault

set -euo pipefail

# Script directory and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/app-configs.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
VAULT_NAME=""
APP_NAME=""
ENVIRONMENT=""
OUTPUT_FILE=""
DRY_RUN=false
VERBOSE=false

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

show_usage() {
    cat << EOF
Environment File Generator - Bash Version

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -a, --app APP           Application name (my-web-app)
    -e, --env ENV           Environment (dev, prod)
    -o, --output FILE       Output file path (default: ./.env)
    -d, --dry-run          Show what would be generated without creating file
    -l, --list-apps        List available applications and environments
    -v, --verbose          Verbose output
    -h, --help             Show this help message

EXAMPLES:
    $0                                              # Interactive mode
    $0 --app my-web-app --env dev             # Generate my-web-app dev .env
    $0 --app my-web-app --env prod --output ./prod.env
    $0 --list-apps                                 # Show available options
    $0 --dry-run --app my-web-app --env dev  # Preview without creating file

REQUIREMENTS:
    - Azure CLI installed and authenticated (az login)
    - jq command-line JSON processor
    - Access to the application secrets Key Vault
EOF
}

check_dependencies() {
    local missing_deps=()

    if ! command -v az &> /dev/null; then
        missing_deps+=("Azure CLI (az)")
    fi

    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing required dependencies:"
        printf '  - %s\n' "${missing_deps[@]}" >&2
        exit 1
    fi
}

check_azure_login() {
    if ! az account show &> /dev/null; then
        log_error "Not logged into Azure. Run 'az login' first."
        exit 1
    fi
}

get_vault_name() {
    log_info "Getting Key Vault name from configuration..."

    # Get vault name from config file
    VAULT_NAME=$(jq -r '.vault_name' "$CONFIG_FILE")

    if [ -z "$VAULT_NAME" ] || [ "$VAULT_NAME" = "null" ]; then
        log_error "Could not get vault_name from configuration file: $CONFIG_FILE"
        exit 1
    fi

    log_info "Found Key Vault: $VAULT_NAME"
}

list_applications() {
    log_info "Available applications and environments:"
    echo

    jq -r '.applications | to_entries[] | "  \(.key) (\(.value.description)):\n    Environments: \(.value.environments | join(", "))\n    Secrets: \(.value.secrets | length) configured\n"' "$CONFIG_FILE"
}

validate_app_env() {
    local app="$1"
    local env="$2"

    # Check if app exists
    if ! jq -e ".applications[\"$app\"]" "$CONFIG_FILE" &> /dev/null; then
        log_error "Application '$app' not found in configuration."
        log_info "Available applications: $(jq -r '.applications | keys | join(", ")' "$CONFIG_FILE")"
        exit 1
    fi

    # Check if environment exists for this app
    if ! jq -e ".applications[\"$app\"].environments | index(\"$env\")" "$CONFIG_FILE" &> /dev/null; then
        log_error "Environment '$env' not available for application '$app'."
        local available_envs
        available_envs=$(jq -r ".applications[\"$app\"].environments | join(\", \")" "$CONFIG_FILE")
        log_info "Available environments for $app: $available_envs"
        exit 1
    fi
}

interactive_mode() {
    log_info "Interactive Environment File Generator"
    echo

    # Show available applications
    echo "Available applications:"
    jq -r '.applications | to_entries[] | "  \(.key) - \(.value.description)"' "$CONFIG_FILE"
    echo

    # Get application
    while true; do
        read -p "Enter application name: " APP_NAME
        if jq -e ".applications[\"$APP_NAME\"]" "$CONFIG_FILE" &> /dev/null; then
            break
        else
            log_error "Invalid application. Please try again."
        fi
    done

    # Show available environments for selected app
    echo
    echo "Available environments for $APP_NAME:"
    jq -r ".applications[\"$APP_NAME\"].environments | .[] | \"  \(.)\"" "$CONFIG_FILE"
    echo

    # Get environment
    while true; do
        read -p "Enter environment: " ENVIRONMENT
        if jq -e ".applications[\"$APP_NAME\"].environments | index(\"$ENVIRONMENT\")" "$CONFIG_FILE" &> /dev/null; then
            break
        else
            log_error "Invalid environment. Please try again."
        fi
    done

    # Get output file
    echo
    read -p "Output file path (default: ./.env): " OUTPUT_FILE
    if [ -z "$OUTPUT_FILE" ]; then
        OUTPUT_FILE="./.env"
    fi
}

get_secret_from_vault() {
    local secret_name="$1"
    local vault_name="$2"

    if [ "$VERBOSE" = true ]; then
        log_info "Fetching secret: $secret_name"
    fi

    local secret_value error_output
    error_output=$(mktemp)

    secret_value=$(az keyvault secret show --name "$secret_name" --vault-name "$vault_name" --query value -o tsv 2>"$error_output")
    local exit_code=$?

    if [ $exit_code -eq 0 ] && [ -n "$secret_value" ]; then
        rm -f "$error_output"
        echo "$secret_value"
    else
        # Check for network access errors
        if grep -q "ForbiddenByFirewall\|network access" "$error_output" 2>/dev/null; then
            log_error "Network access denied to Key Vault. Ensure you have network access to the vault."
            log_info "Key Vault requires VPN connection or access from approved IP ranges."
            log_info "Check your Key Vault's firewall settings and ensure your IP is allowed."
            rm -f "$error_output"
            exit 1
        elif grep -q "SecretNotFound" "$error_output" 2>/dev/null; then
            # Secret doesn't exist, this is handled by caller
            rm -f "$error_output"
            echo ""
        else
            # Other error, show if verbose
            if [ "$VERBOSE" = true ] && [ -f "$error_output" ]; then
                log_warning "Error fetching secret '$secret_name': $(cat "$error_output")"
            fi
            rm -f "$error_output"
            echo ""
        fi
    fi
}

generate_env_content() {
    local app="$1"
    local env="$2"

    log_info "Generating .env content for $app ($env environment)..."

    local env_content=""
    local missing_secrets=()
    local found_secrets=0
    local total_secrets

    total_secrets=$(jq -r ".applications[\"$app\"].secrets | length" "$CONFIG_FILE")

    # Add header
    env_content+="# ============================================================================="
    env_content+="\n# Environment Variables for $app ($env environment)"
    env_content+="\n# Generated on: $(date)"
    env_content+="\n# Key Vault: $VAULT_NAME"
    env_content+="\n# ============================================================================="
    env_content+="\n"

    # Process each secret
    local current_category=""

    while IFS= read -r secret_json; do
        local env_var category vault_key description secret_name secret_value

        env_var=$(echo "$secret_json" | jq -r '.env_var')
        category=$(echo "$secret_json" | jq -r '.category')
        vault_key=$(echo "$secret_json" | jq -r '.vault_key')
        description=$(echo "$secret_json" | jq -r '.description')

        # Add category header if it changed
        if [ "$category" != "$current_category" ]; then
            env_content+="\n# $(echo "$category" | tr '[:lower:]' '[:upper:]')\n"
            current_category="$category"
        fi

        # Build secret name using naming convention
        secret_name="${app}-${env}-${vault_key}"

        # Get secret value from vault
        secret_value=$(get_secret_from_vault "$secret_name" "$VAULT_NAME")

        if [ -n "$secret_value" ]; then
            env_content+="${env_var}=${secret_value}\n"
            ((found_secrets++))
            if [ "$VERBOSE" = true ]; then
                log_success "Found: $env_var"
            fi
        else
            env_content+="${env_var}=\n"
            missing_secrets+=("$secret_name")
            if [ "$VERBOSE" = true ]; then
                log_warning "Missing: $env_var (vault key: $secret_name)"
            fi
        fi

    done < <(jq -c ".applications[\"$app\"].secrets[]" "$CONFIG_FILE")

    # Show summary
    log_info "Secrets summary: $found_secrets/$total_secrets found"

    if [ ${#missing_secrets[@]} -gt 0 ]; then
        log_warning "Missing secrets in Key Vault:"
        printf '  - %s\n' "${missing_secrets[@]}" >&2
        echo >&2
        log_info "To add missing secrets, use:"
        log_info "az keyvault secret set --vault-name \"$VAULT_NAME\" --name \"SECRET_NAME\" --value \"SECRET_VALUE\""
    fi

    echo -e "$env_content"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -a|--app)
                APP_NAME="$2"
                shift 2
                ;;
            -e|--env)
                ENVIRONMENT="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -l|--list-apps)
                list_applications
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Check dependencies
    check_dependencies
    check_azure_login

    # Verify configuration file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi

    # Get Key Vault name
    get_vault_name

    # Interactive mode if no app specified
    if [ -z "$APP_NAME" ] || [ -z "$ENVIRONMENT" ]; then
        interactive_mode
    fi

    # Validate app and environment
    validate_app_env "$APP_NAME" "$ENVIRONMENT"

    # Set default output file if not specified
    if [ -z "$OUTPUT_FILE" ]; then
        OUTPUT_FILE="./.env"
    fi

    # Generate content
    local env_content
    env_content=$(generate_env_content "$APP_NAME" "$ENVIRONMENT")

    if [ "$DRY_RUN" = true ]; then
        log_info "DRY RUN - Content that would be written to $OUTPUT_FILE:"
        echo "----------------------------------------"
        echo -e "$env_content"
        echo "----------------------------------------"
    else
        # Write to file
        echo -e "$env_content" > "$OUTPUT_FILE"
        log_success "Environment file generated: $OUTPUT_FILE"

        # Show file info
        local file_size
        file_size=$(wc -l < "$OUTPUT_FILE")
        log_info "File contains $file_size lines"
    fi
}

# Run main function with all arguments
main "$@"
