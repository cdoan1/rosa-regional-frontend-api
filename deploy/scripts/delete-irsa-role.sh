#!/bin/bash
#
# Script to delete the IAM role for rosa-regional-frontend-api IRSA
# This cleans up resources created by create-irsa-role.sh
#
# Prerequisites:
#   - AWS CLI configured with appropriate permissions
#
# Usage:
#   ./delete-irsa-role.sh [OPTIONS]
#
# Example:
#   ./delete-irsa-role.sh
#   ./delete-irsa-role.sh --role-name custom-role-name --force
#

set -euo pipefail

# Default values (must match create-irsa-role.sh)
ROLE_NAME="rosa-regional-frontend-api-role"
POLICY_NAME="${ROLE_NAME}-policy"
FORCE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Optional:
  --role-name       IAM role name (default: rosa-regional-frontend-api-role)
  --force           Skip confirmation prompt
  --help            Show this help message

Example:
  $0
  $0 --role-name custom-role-name --force
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --role-name)
            ROLE_NAME="$2"
            POLICY_NAME="${ROLE_NAME}-policy"
            shift 2
            ;;
        --force) FORCE=true; shift ;;
        --help) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# Check for required tools
command -v aws &> /dev/null || { log_error "aws CLI is required but not installed."; exit 1; }

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
    log_error "Failed to get AWS account ID. Check your AWS credentials."
    exit 1
}

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

log_info "rosa-regional-frontend-api IRSA Cleanup"
log_info "=========================================="
log_info "  AWS Account ID: $ACCOUNT_ID"
log_info "  Role Name:      $ROLE_NAME"
log_info "  Policy Name:    $POLICY_NAME"
log_info "  Policy ARN:     $POLICY_ARN"
log_info ""

# Confirmation prompt
if [[ "$FORCE" != "true" ]]; then
    echo -e "${YELLOW}WARNING: This will delete the following resources:${NC}"
    echo "  - IAM Role: $ROLE_NAME"
    echo "  - IAM Policy: $POLICY_NAME"
    echo ""
    read -p "Are you sure you want to continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborted."
        exit 0
    fi
fi

# Detach policies from role
log_info "Detaching policies from role..."
if aws iam get-role --role-name "$ROLE_NAME" &> /dev/null; then
    # List and detach all attached policies
    ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
        --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null || true)
    
    for policy_arn in $ATTACHED_POLICIES; do
        if [[ -n "$policy_arn" ]]; then
            log_info "  Detaching policy: $policy_arn"
            aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$policy_arn" || true
        fi
    done
    
    # List and delete inline policies
    INLINE_POLICIES=$(aws iam list-role-policies --role-name "$ROLE_NAME" \
        --query 'PolicyNames' --output text 2>/dev/null || true)
    
    for policy_name in $INLINE_POLICIES; do
        if [[ -n "$policy_name" ]]; then
            log_info "  Deleting inline policy: $policy_name"
            aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$policy_name" || true
        fi
    done
else
    log_warn "Role $ROLE_NAME does not exist, skipping policy detachment."
fi

# Delete IAM role
log_info "Deleting IAM role: $ROLE_NAME"
if aws iam get-role --role-name "$ROLE_NAME" &> /dev/null; then
    aws iam delete-role --role-name "$ROLE_NAME"
    log_info "  Role deleted successfully."
else
    log_warn "  Role does not exist, skipping."
fi

# Delete IAM policy (and all versions)
log_info "Deleting IAM policy: $POLICY_NAME"
if aws iam get-policy --policy-arn "$POLICY_ARN" &> /dev/null; then
    # Delete all non-default policy versions first
    VERSIONS=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
        --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null || true)
    
    for version_id in $VERSIONS; do
        if [[ -n "$version_id" ]]; then
            log_info "  Deleting policy version: $version_id"
            aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$version_id" || true
        fi
    done
    
    # Delete the policy
    aws iam delete-policy --policy-arn "$POLICY_ARN"
    log_info "  Policy deleted successfully."
else
    log_warn "  Policy does not exist, skipping."
fi

log_info ""
log_info "=========================================="
log_info "Cleanup completed!"
log_info "=========================================="
log_info ""
log_info "Note: The following resources were NOT deleted:"
log_info "  - OIDC provider (shared by other IRSA roles)"
log_info "  - DynamoDB table (rosa-customer-accounts)"
log_info "  - Kubernetes resources (ServiceAccount, Deployment, etc.)"
log_info ""
log_info "To delete Kubernetes resources, run:"
log_info "  kubectl delete -k deploy/kubernetes/"
log_info ""
log_info "To delete the DynamoDB table, run:"
log_info "  aws dynamodb delete-table --table-name rosa-customer-accounts --region <region>"
