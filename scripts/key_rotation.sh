#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
#
# Key Rotation Script for ArcherDB Encryption
#
# This script handles key rotation for ArcherDB's encryption at rest feature.
# It supports multiple key storage backends: file, environment variable, AWS KMS, and HashiCorp Vault.
#
# Usage:
#   ./key_rotation.sh --key-type=file --key-path=/path/to/key [options]
#   ./key_rotation.sh --key-type=env --key-var=ARCHERDB_ENCRYPTION_KEY [options]
#   ./key_rotation.sh --key-type=kms --key-arn=arn:aws:kms:... [options]
#   ./key_rotation.sh --key-type=vault --vault-addr=... --key-name=... [options]
#
# Options:
#   --dry-run          Show what would happen without making changes
#   --verify           Verify current key status
#   --rollback         Restore previous key (requires backup)
#   --backup-dir=PATH  Directory for key backups (default: /var/lib/archerdb/key-backups)
#   --data-dir=PATH    ArcherDB data directory (default: /var/lib/archerdb/data)
#   --force            Skip confirmation prompts
#   --verbose          Enable verbose output
#
# Exit codes:
#   0 - Success
#   1 - General error
#   2 - Invalid arguments
#   3 - Key provider error
#   4 - Verification failed
#   5 - Rollback failed

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_BACKUP_DIR="/var/lib/archerdb/key-backups"
DEFAULT_DATA_DIR="/var/lib/archerdb/data"
DEFAULT_LOG_FILE="/var/log/archerdb/key-rotation.log"
LOG_FILE="${ARCHERDB_KEY_ROTATION_LOG:-$DEFAULT_LOG_FILE}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Logging
# =============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] INFO: $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] WARN: $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_verbose() {
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# =============================================================================
# Usage and Help
# =============================================================================

print_usage() {
    cat << 'EOF'
ArcherDB Key Rotation Script

USAGE:
    key_rotation.sh --key-type=TYPE [OPTIONS]

KEY TYPES:
    file        File-based key (verify/rollback or dry-run preview only)
    env         Environment variable key (verify or dry-run preview only)
    kms         AWS Key Management Service (production)
    vault       HashiCorp Vault Transit (production)

OPTIONS:
    --dry-run               Show what would happen without making changes
    --verify                Verify current key status and exit
    --rollback              Restore previous key from backup
    --backup-dir=PATH       Key backup directory (default: /var/lib/archerdb/key-backups)
    --data-dir=PATH         ArcherDB data directory (default: /var/lib/archerdb/data)
    --force                 Skip confirmation prompts
    --verbose               Enable verbose output

FILE KEY OPTIONS:
    --key-path=PATH         Path to encryption key file (required)
    --new-key-path=PATH     Path to new key file (optional, generates if not provided)

ENV KEY OPTIONS:
    --key-var=NAME          Environment variable name (required)

AWS KMS OPTIONS:
    --key-arn=ARN           KMS key ARN (required)
    --region=REGION         AWS region (optional, derived from ARN)

VAULT OPTIONS:
    --vault-addr=URL        Vault server address (required)
    --key-name=NAME         Transit key name (required)
    --mount-path=PATH       Transit mount path (default: transit)
    --namespace=NS          Vault namespace (optional)

EXAMPLES:
    # Verify file-based key
    ./key_rotation.sh --key-type=file --key-path=/etc/archerdb/key.bin --verify

    # Dry-run rotation for file key
    ./key_rotation.sh --key-type=file --key-path=/etc/archerdb/key.bin --dry-run

    # Preview file-based key rotation requirements
    ./key_rotation.sh --key-type=file --key-path=/etc/archerdb/key.bin --dry-run

    # Configure or trigger AWS KMS-managed rotation
    ./key_rotation.sh --key-type=kms --key-arn=arn:aws:kms:us-east-1:123456789:key/abc123

    # Rotate a Vault Transit key version
    ./key_rotation.sh --key-type=vault --vault-addr=https://vault.example.com:8200 --key-name=archerdb

    # Rollback to previous key
    ./key_rotation.sh --key-type=file --key-path=/etc/archerdb/key.bin --rollback

EOF
}

# =============================================================================
# Argument Parsing
# =============================================================================

parse_args() {
    DRY_RUN="false"
    VERIFY_ONLY="false"
    ROLLBACK="false"
    FORCE="false"
    VERBOSE="false"
    KEY_TYPE=""
    KEY_PATH=""
    NEW_KEY_PATH=""
    KEY_VAR=""
    KEY_ARN=""
    REGION=""
    VAULT_ADDR=""
    KEY_NAME=""
    MOUNT_PATH="transit"
    NAMESPACE=""
    BACKUP_DIR="$DEFAULT_BACKUP_DIR"
    DATA_DIR="$DEFAULT_DATA_DIR"

    if [[ $# -eq 0 ]]; then
        DRY_RUN="true"
        FORCE="true"
        KEY_TYPE="file"
        KEY_PATH="${TMPDIR:-/tmp}/archerdb-key-rotation-selfcheck.bin"
        NEW_KEY_PATH="${KEY_PATH}.new"
        BACKUP_DIR="${TMPDIR:-/tmp}/archerdb-key-backups"
        DATA_DIR="${TMPDIR:-/tmp}/archerdb-data"

        local current_size=0
        if [[ -f "$KEY_PATH" ]]; then
            current_size=$(wc -c < "$KEY_PATH" 2>/dev/null || echo 0)
        fi
        if [[ ! -f "$KEY_PATH" || "$current_size" -ne 32 ]]; then
            if command -v openssl &>/dev/null; then
                openssl rand -out "$KEY_PATH" 32
            else
                dd if=/dev/urandom of="$KEY_PATH" bs=32 count=1 2>/dev/null
            fi
            chmod 600 "$KEY_PATH" 2>/dev/null || true
        fi

        log_warn "No arguments provided; running dry-run self-check with key-type=file"
        return 0
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --verify)
                VERIFY_ONLY="true"
                shift
                ;;
            --rollback)
                ROLLBACK="true"
                shift
                ;;
            --force)
                FORCE="true"
                shift
                ;;
            --verbose)
                VERBOSE="true"
                shift
                ;;
            --key-type=*)
                KEY_TYPE="${1#*=}"
                shift
                ;;
            --key-path=*)
                KEY_PATH="${1#*=}"
                shift
                ;;
            --new-key-path=*)
                NEW_KEY_PATH="${1#*=}"
                shift
                ;;
            --key-var=*)
                KEY_VAR="${1#*=}"
                shift
                ;;
            --key-arn=*)
                KEY_ARN="${1#*=}"
                shift
                ;;
            --region=*)
                REGION="${1#*=}"
                shift
                ;;
            --vault-addr=*)
                VAULT_ADDR="${1#*=}"
                shift
                ;;
            --key-name=*)
                KEY_NAME="${1#*=}"
                shift
                ;;
            --mount-path=*)
                MOUNT_PATH="${1#*=}"
                shift
                ;;
            --namespace=*)
                NAMESPACE="${1#*=}"
                shift
                ;;
            --backup-dir=*)
                BACKUP_DIR="${1#*=}"
                shift
                ;;
            --data-dir=*)
                DATA_DIR="${1#*=}"
                shift
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 2
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$KEY_TYPE" ]]; then
        log_error "Missing required argument: --key-type"
        exit 2
    fi

    case "$KEY_TYPE" in
        file)
            if [[ -z "$KEY_PATH" ]]; then
                log_error "File key type requires --key-path"
                exit 2
            fi
            ;;
        env)
            if [[ -z "$KEY_VAR" ]]; then
                log_error "Env key type requires --key-var"
                exit 2
            fi
            ;;
        kms)
            if [[ -z "$KEY_ARN" ]]; then
                log_error "KMS key type requires --key-arn"
                exit 2
            fi
            ;;
        vault)
            if [[ -z "$VAULT_ADDR" ]] || [[ -z "$KEY_NAME" ]]; then
                log_error "Vault key type requires --vault-addr and --key-name"
                exit 2
            fi
            ;;
        *)
            log_error "Unknown key type: $KEY_TYPE"
            exit 2
            ;;
    esac
}

# =============================================================================
# File Key Operations
# =============================================================================

verify_file_key() {
    local key_path="$1"

    log_info "Verifying file-based key at: $key_path"

    if [[ ! -f "$key_path" ]]; then
        log_error "Key file not found: $key_path"
        return 4
    fi

    local size
    size=$(stat -c%s "$key_path" 2>/dev/null || stat -f%z "$key_path" 2>/dev/null)
    if [[ "$size" -ne 32 ]]; then
        log_error "Key file has incorrect size: $size bytes (expected 32)"
        return 4
    fi

    # Check permissions (should be 0400 or 0600)
    local perms
    perms=$(stat -c%a "$key_path" 2>/dev/null || stat -f%Lp "$key_path" 2>/dev/null)
    if [[ "$perms" != "400" ]] && [[ "$perms" != "600" ]]; then
        log_warn "Key file has insecure permissions: $perms (expected 400 or 600)"
    else
        log_verbose "Key file permissions: $perms (OK)"
    fi

    log_info "Key verification: PASSED"
    log_info "  Path: $key_path"
    log_info "  Size: $size bytes"
    log_info "  Permissions: $perms"

    return 0
}

generate_file_key() {
    local key_path="$1"

    log_info "Generating new 256-bit encryption key"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would generate new key at: $key_path"
        return 0
    fi

    # Generate 32 bytes (256 bits) of random data
    if command -v openssl &>/dev/null; then
        openssl rand -out "$key_path" 32
    else
        dd if=/dev/urandom of="$key_path" bs=32 count=1 2>/dev/null
    fi

    # Set strict permissions
    chmod 400 "$key_path"

    log_info "Generated new key: $key_path"
}

backup_file_key() {
    local key_path="$1"
    local backup_dir="$2"

    local timestamp
    timestamp=$(date -u '+%Y%m%d_%H%M%S')
    local backup_path="${backup_dir}/key_${timestamp}.bin"

    log_info "Backing up current key to: $backup_path"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would backup key to: $backup_path"
        return 0
    fi

    mkdir -p "$backup_dir"
    cp -p "$key_path" "$backup_path"
    chmod 400 "$backup_path"

    log_info "Key backed up successfully"
}

rotate_file_key() {
    local old_key_path="$KEY_PATH"
    local new_key_path="${NEW_KEY_PATH:-${KEY_PATH}.new}"

    log_info "=== File Key Rotation ==="

    # Step 1: Verify current key
    verify_file_key "$old_key_path" || return $?

    if [[ "$DRY_RUN" == "true" ]]; then
        backup_file_key "$old_key_path" "$BACKUP_DIR" || return $?
        if [[ -f "$new_key_path" ]]; then
            log_info "[DRY-RUN] Would use provided new key: $new_key_path"
            verify_file_key "$new_key_path" || return $?
        else
            log_info "[DRY-RUN] Would generate new key at: $new_key_path"
        fi
        log_info "[DRY-RUN] Automatic file-key rotation is not available in this release"
        log_info "[DRY-RUN] A separate offline DEK re-wrap or export/import workflow is required"
        return 0
    fi

    log_error "Automatic rotation for file-based master keys is not available in this release"
    log_error "Replacing the file key without re-wrapping stored DEKs would make encrypted files unreadable"
    log_info "Supported paths:"
    log_info "  1. Use --verify or --rollback only for file-based keys"
    log_info "  2. Migrate to a provider-managed key backend (KMS or Vault)"
    log_info "  3. Perform an offline export/import or DEK re-wrap workflow before replacing the key file"
    return 3
}

rollback_file_key() {
    log_info "=== File Key Rollback ==="

    # Find most recent backup
    local latest_backup
    latest_backup=$(ls -t "$BACKUP_DIR"/key_*.bin 2>/dev/null | head -1)

    if [[ -z "$latest_backup" ]]; then
        log_error "No backup found in: $BACKUP_DIR"
        return 5
    fi

    log_info "Found backup: $latest_backup"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would restore key from: $latest_backup"
        log_info "[DRY-RUN] Would replace: $KEY_PATH"
        return 0
    fi

    if [[ "$FORCE" != "true" ]]; then
        echo -n "Restore key from $latest_backup? [y/N] "
        read -r response
        if [[ "$response" != "y" ]] && [[ "$response" != "Y" ]]; then
            log_info "Rollback cancelled"
            return 0
        fi
    fi

    cp -p "$latest_backup" "$KEY_PATH"
    log_info "Key restored from backup"

    return 0
}

# =============================================================================
# AWS KMS Operations
# =============================================================================

verify_kms_key() {
    local key_arn="$1"

    log_info "Verifying AWS KMS key: $key_arn"

    if ! command -v aws &>/dev/null; then
        log_error "AWS CLI not found. Install: pip install awscli"
        return 3
    fi

    local region="${REGION:-}"
    if [[ -z "$region" ]]; then
        region=$(echo "$key_arn" | cut -d: -f4)
    fi

    # Check key exists and is enabled
    local key_info
    key_info=$(aws kms describe-key --key-id "$key_arn" --region "$region" 2>&1) || {
        log_error "Failed to access KMS key: $key_info"
        return 3
    }

    local key_state
    key_state=$(echo "$key_info" | grep -o '"KeyState": "[^"]*"' | cut -d'"' -f4)

    if [[ "$key_state" != "Enabled" ]]; then
        log_error "KMS key is not enabled. State: $key_state"
        return 4
    fi

    log_info "Key verification: PASSED"
    log_info "  ARN: $key_arn"
    log_info "  Region: $region"
    log_info "  State: $key_state"

    return 0
}

rotate_kms_key() {
    log_info "=== AWS KMS Key Rotation ==="

    local region="${REGION:-}"
    if [[ -z "$region" ]]; then
        region=$(echo "$KEY_ARN" | cut -d: -f4)
    fi

    # Step 1: Verify current key
    verify_kms_key "$KEY_ARN" || return $?

    # Step 2: Enable automatic key rotation (if not already enabled)
    log_info "Enabling automatic key rotation..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would enable rotation for: $KEY_ARN"
    else
        aws kms enable-key-rotation --key-id "$KEY_ARN" --region "$region" || {
            log_error "Failed to enable key rotation"
            return 3
        }
    fi

    # Step 3: Trigger immediate rotation (optional)
    log_info "AWS KMS automatically rotates keys annually."
    log_info "To trigger immediate rotation, use AWS console or:"
    log_info "  aws kms rotate-key-on-demand --key-id $KEY_ARN --region $region"

    # Step 4: Document ciphertext compatibility
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Existing wrapped DEKs remain decryptable because KMS tracks key material versions"
        log_info "[DRY-RUN] Optional bulk DEK re-wrap is not performed by this helper"
    else
        log_info "Existing wrapped DEKs remain decryptable because KMS tracks key material versions"
        log_info "Optional bulk DEK re-wrap is not required for correctness and is not performed by this helper"
    fi

    log_info "=== KMS Key Rotation Complete ==="

    return 0
}

# =============================================================================
# HashiCorp Vault Operations
# =============================================================================

verify_vault_key() {
    log_info "Verifying Vault key: $KEY_NAME at $VAULT_ADDR"

    if ! command -v vault &>/dev/null; then
        log_error "Vault CLI not found. Install: https://www.vaultproject.io/downloads"
        return 3
    fi

    # Check Vault is accessible
    local vault_status
    vault_status=$(VAULT_ADDR="$VAULT_ADDR" vault status -format=json 2>&1) || {
        log_error "Failed to connect to Vault: $vault_status"
        return 3
    }

    local sealed
    sealed=$(echo "$vault_status" | grep -o '"sealed": [^,]*' | cut -d: -f2 | tr -d ' ')
    if [[ "$sealed" == "true" ]]; then
        log_error "Vault is sealed"
        return 3
    fi

    # Check key exists
    local key_info
    key_info=$(VAULT_ADDR="$VAULT_ADDR" vault read -format=json "$MOUNT_PATH/keys/$KEY_NAME" 2>&1) || {
        log_error "Failed to read key: $key_info"
        return 3
    }

    local latest_version
    latest_version=$(echo "$key_info" | grep -o '"latest_version": [0-9]*' | cut -d: -f2 | tr -d ' ')

    log_info "Key verification: PASSED"
    log_info "  Address: $VAULT_ADDR"
    log_info "  Key: $MOUNT_PATH/$KEY_NAME"
    log_info "  Latest version: $latest_version"

    return 0
}

rotate_vault_key() {
    log_info "=== HashiCorp Vault Key Rotation ==="

    # Step 1: Verify current key
    verify_vault_key || return $?

    # Step 2: Rotate key in Vault
    log_info "Rotating key in Vault Transit engine..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would rotate: $MOUNT_PATH/keys/$KEY_NAME"
    else
        VAULT_ADDR="$VAULT_ADDR" vault write -f "$MOUNT_PATH/keys/$KEY_NAME/rotate" || {
            log_error "Failed to rotate key"
            return 3
        }
    fi

    # Step 3: Document ciphertext compatibility
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Existing wrapped DEKs remain decryptable through older Vault key versions"
        log_info "[DRY-RUN] Optional bulk rewrap is not performed by this helper"
    else
        log_info "Existing wrapped DEKs remain decryptable through older Vault key versions"
        log_info "Optional bulk rewrap is not required for correctness and is not performed by this helper"
    fi

    # Step 4: Verify new key version
    verify_vault_key || return $?

    log_info "=== Vault Key Rotation Complete ==="

    return 0
}

# =============================================================================
# Environment Variable Key Operations
# =============================================================================

verify_env_key() {
    local key_var="$1"

    log_info "Verifying environment variable key: $key_var"

    local key_value="${!key_var:-}"
    if [[ -z "$key_value" ]]; then
        log_error "Environment variable not set: $key_var"
        return 4
    fi

    # Decode base64 and check length
    local decoded_len
    decoded_len=$(echo -n "$key_value" | base64 -d 2>/dev/null | wc -c)

    if [[ "$decoded_len" -ne 32 ]]; then
        log_error "Key has incorrect length: $decoded_len bytes (expected 32)"
        return 4
    fi

    log_info "Key verification: PASSED"
    log_info "  Variable: $key_var"
    log_info "  Length: $decoded_len bytes (base64 encoded)"

    return 0
}

rotate_env_key() {
    log_info "=== Environment Variable Key Rotation ==="

    # Step 1: Verify current key
    verify_env_key "$KEY_VAR" || return $?

    # Step 2: Generate new key material for preview
    local new_key_b64
    if command -v openssl &>/dev/null; then
        new_key_b64=$(openssl rand -base64 32)
    else
        new_key_b64=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64)
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would update environment variable: $KEY_VAR"
        log_info "[DRY-RUN] New key value: ***REDACTED***"
        log_info "[DRY-RUN] Automatic env-key rotation is not available in this release"
        log_info "[DRY-RUN] A separate offline DEK re-wrap or export/import workflow is required"
        return 0
    fi

    log_error "Automatic rotation for environment-variable master keys is not available in this release"
    log_error "Replacing $KEY_VAR without re-wrapping stored DEKs would make encrypted files unreadable"
    log_info "Preview of the next key value is available only in --dry-run mode"
    log_info "Supported paths: migrate to KMS/Vault or perform an offline re-encryption workflow first"
    return 3
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
    # Create log directory; fall back to a writable temp path if needed.
    local log_dir
    log_dir="$(dirname "$LOG_FILE")"
    if ! mkdir -p "$log_dir" 2>/dev/null; then
        LOG_FILE="${TMPDIR:-/tmp}/archerdb-key-rotation.log"
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    fi

    parse_args "$@"

    log_info "ArcherDB Key Rotation Script"
    log_info "Key type: $KEY_TYPE"
    log_verbose "Dry run: $DRY_RUN"
    log_verbose "Verify only: $VERIFY_ONLY"
    log_verbose "Rollback: $ROLLBACK"

    case "$KEY_TYPE" in
        file)
            if [[ "$VERIFY_ONLY" == "true" ]]; then
                verify_file_key "$KEY_PATH"
            elif [[ "$ROLLBACK" == "true" ]]; then
                rollback_file_key
            else
                rotate_file_key
            fi
            ;;
        env)
            if [[ "$VERIFY_ONLY" == "true" ]]; then
                verify_env_key "$KEY_VAR"
            elif [[ "$ROLLBACK" == "true" ]]; then
                log_error "Rollback not supported for environment variable keys"
                exit 5
            else
                rotate_env_key
            fi
            ;;
        kms)
            if [[ "$VERIFY_ONLY" == "true" ]]; then
                verify_kms_key "$KEY_ARN"
            elif [[ "$ROLLBACK" == "true" ]]; then
                log_warn "KMS key rollback is handled by AWS - contact AWS support"
                exit 5
            else
                rotate_kms_key
            fi
            ;;
        vault)
            if [[ "$VERIFY_ONLY" == "true" ]]; then
                verify_vault_key
            elif [[ "$ROLLBACK" == "true" ]]; then
                log_warn "Vault key rollback: set min_decryption_version in Vault"
                log_info "vault write $MOUNT_PATH/keys/$KEY_NAME/config min_decryption_version=N"
                exit 5
            else
                rotate_vault_key
            fi
            ;;
    esac

    exit $?
}

main "$@"
