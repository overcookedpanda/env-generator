#!/usr/bin/env python3
"""
Upload secrets from .env file to Azure Key Vault
Based on app-configs.json configuration

Usage:
    python upload-secrets.py --env-file /path/to/.env --environment dev
    python upload-secrets.py --env-file /path/to/.env --environment prod
    python upload-secrets.py --env-file /path/to/.env --environment dev --dry-run

Requirements:
    pip install azure-keyvault-secrets azure-identity python-dotenv
"""

import sys
import json
import argparse
from pathlib import Path
from typing import Dict

from azure.keyvault.secrets import SecretClient
from azure.identity import DefaultAzureCredential
from dotenv import dotenv_values

# Script configuration
SCRIPT_DIR = Path(__file__).parent
CONFIG_FILE = SCRIPT_DIR / "app-configs.json"


# Colors for console output
class Colors:
    BLUE = "\033[0;34m"
    GREEN = "\033[0;32m"
    YELLOW = "\033[1;33m"
    RED = "\033[0;31m"
    NC = "\033[0m"  # No Color


def log_info(message: str):
    print(f"{Colors.BLUE}[INFO]{Colors.NC} {message}")


def log_success(message: str):
    print(f"{Colors.GREEN}[SUCCESS]{Colors.NC} {message}")


def log_warning(message: str):
    print(f"{Colors.YELLOW}[WARNING]{Colors.NC} {message}")


def log_error(message: str):
    print(f"{Colors.RED}[ERROR]{Colors.NC} {message}")


def load_config() -> dict:
    """Load configuration from app-configs.json"""
    try:
        with open(CONFIG_FILE, "r") as f:
            config = json.load(f)
        log_info("Configuration loaded successfully")
        return config
    except FileNotFoundError:
        log_error(f"Configuration file not found: {CONFIG_FILE}")
        sys.exit(1)
    except json.JSONDecodeError as e:
        log_error(f"Failed to parse configuration file: {e}")
        sys.exit(1)


def load_env_file(env_file_path: str) -> Dict[str, str]:
    """Load environment variables from .env file"""
    if not Path(env_file_path).exists():
        log_error(f"Environment file not found: {env_file_path}")
        sys.exit(1)

    try:
        env_vars = dotenv_values(env_file_path)
        # Filter out empty values and comments
        env_vars = {k: v for k, v in env_vars.items() if v and not k.startswith("#")}
        log_info(f"Loaded {len(env_vars)} environment variables from {env_file_path}")
        return env_vars
    except Exception as e:
        log_error(f"Failed to load environment file: {e}")
        sys.exit(1)


def create_secret_mapping(
    config: dict, app_name: str, environment: str, env_vars: Dict[str, str]
) -> Dict[str, str]:
    """Create mapping from Key Vault secret names to values from .env file"""
    if app_name not in config["applications"]:
        log_error(f"Application '{app_name}' not found in configuration")
        sys.exit(1)

    app_config = config["applications"][app_name]
    if environment not in app_config["environments"]:
        log_error(
            f"Environment '{environment}' not supported for application '{app_name}'"
        )
        sys.exit(1)

    secret_mapping = {}
    missing_vars = []

    for secret_config in app_config["secrets"]:
        env_var = secret_config["env_var"]
        vault_key = secret_config["vault_key"]

        # Build Key Vault secret name using naming convention
        secret_name = f"{app_name}-{environment}-{vault_key}"

        if env_var in env_vars:
            secret_mapping[secret_name] = env_vars[env_var]
        else:
            missing_vars.append(env_var)

    if missing_vars:
        log_warning("Missing environment variables in .env file:")
        for var in missing_vars:
            log_warning(f"  - {var}")

    log_info(f"Mapped {len(secret_mapping)} secrets for upload")
    return secret_mapping


def upload_secrets(
    vault_name: str, secret_mapping: Dict[str, str], dry_run: bool = False
):
    """Upload secrets to Azure Key Vault"""
    if dry_run:
        log_info("DRY RUN - Secrets that would be uploaded:")
        print("=" * 60)
        for secret_name, secret_value in secret_mapping.items():
            # Mask the value for security
            masked_value = (
                secret_value[:4] + "*" * (len(secret_value) - 4)
                if len(secret_value) > 4
                else "****"
            )
            print(f"{secret_name} = {masked_value}")
        print("=" * 60)
        log_info(f"Total secrets to upload: {len(secret_mapping)}")
        return

    # Initialize Azure Key Vault client
    try:
        kv_uri = f"https://{vault_name}.vault.azure.net"
        credential = DefaultAzureCredential()
        client = SecretClient(vault_url=kv_uri, credential=credential)
        log_info(f"Connected to Key Vault: {vault_name}")
    except Exception as e:
        log_error(f"Failed to connect to Key Vault: {e}")
        log_error(
            "Make sure you're authenticated (az login) and have access to the Key Vault"
        )
        sys.exit(1)

    # Upload secrets
    uploaded_count = 0
    failed_count = 0

    for secret_name, secret_value in secret_mapping.items():
        try:
            log_info(f"Uploading secret: {secret_name}")
            client.set_secret(secret_name, secret_value)
            uploaded_count += 1
            log_success(f"Uploaded: {secret_name}")
        except Exception as e:
            failed_count += 1
            log_error(f"Failed to upload {secret_name}: {e}")

    # Summary
    print("\n" + "=" * 60)
    log_success(f"Upload complete: {uploaded_count} secrets uploaded")
    if failed_count > 0:
        log_warning(f"Failed uploads: {failed_count} secrets")
    print("=" * 60)


def main():
    parser = argparse.ArgumentParser(
        description="Upload secrets from .env file to Azure Key Vault",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python upload-secrets.py --env-file .env --environment dev
  python upload-secrets.py --env-file ./prod.env --environment prod --dry-run
  python upload-secrets.py --env-file /path/to/.env --environment dev
        """,
    )

    parser.add_argument(
        "--env-file", required=True, help="Path to the .env file containing secrets"
    )

    parser.add_argument(
        "--environment",
        required=True,
        choices=["dev", "staging", "prod"],
        help="Target environment (dev, staging, or prod)",
    )

    parser.add_argument(
        "--app",
        default="my-web-app",
        help="Application name (default: my-web-app)",
    )

    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be uploaded without actually uploading",
    )

    args = parser.parse_args()

    # Load configuration
    config = load_config()
    vault_name = config["vault_name"]

    # Load environment file
    env_vars = load_env_file(args.env_file)

    # Create secret mapping
    secret_mapping = create_secret_mapping(config, args.app, args.environment, env_vars)

    if not secret_mapping:
        log_warning("No secrets to upload")
        return

    # Upload secrets
    upload_secrets(vault_name, secret_mapping, args.dry_run)

    if not args.dry_run:
        log_info("To generate .env files from uploaded secrets, use:")
        log_info(f"  ./generate-env.sh --app {args.app} --env {args.environment}")


if __name__ == "__main__":
    main()
