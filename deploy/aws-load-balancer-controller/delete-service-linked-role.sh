#!/bin/bash
#
# Script to delete the AWS Service-Linked Role for Elastic Load Balancing
#
# IMPORTANT: This role is automatically created by AWS when you use ELB services.
# Deleting it will prevent you from creating new load balancers until AWS
# recreates it (which happens automatically when needed).
#
# Prerequisites:
#   - AWS CLI configured with appropriate permissions
#   - All load balancers must be deleted first
#
# Usage:
#   ./delete-service-linked-role.sh [OPTIONS]
#

set -euo pipefail

ROLE_NAME="AWSServiceRoleForElasticLoadBalancing"
FORCE=false
CHECK_ONLY=false

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

Options:
  --check           Only check if the role exists and list load balancers (no deletion)
  --force           Skip confirmation prompt
  --help            Show this help message

IMPORTANT:
  - All load balancers (ALB, NLB, CLB) must be deleted before this role can be deleted
  - AWS will automatically recreate this role when you create a new load balancer
  - This is a service-linked role, not a regular IAM role

Example:
  $0 --check        # Check status only
  $0 --force        # Delete without confirmation
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --check) CHECK_ONLY=true; shift ;;
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

log_info "AWS Service-Linked Role Cleanup"
log_info "================================"
log_info "  AWS Account ID: $ACCOUNT_ID"
log_info "  Role Name:      $ROLE_NAME"
log_info ""

# Check if role exists
log_info "Checking if service-linked role exists..."
if ! aws iam get-role --role-name "$ROLE_NAME" &> /dev/null; then
    log_info "Role $ROLE_NAME does not exist. Nothing to delete."
    exit 0
fi

log_info "Role exists. Checking for dependent resources..."

# Check for existing load balancers
log_info ""
log_info "Checking for existing load balancers..."

# Check ALBs and NLBs (v2)
log_info "  Application and Network Load Balancers (ELBv2):"
ELBV2_COUNT=$(aws elbv2 describe-load-balancers --query 'LoadBalancers | length(@)' --output text 2>/dev/null || echo "0")
if [[ "$ELBV2_COUNT" -gt 0 ]]; then
    log_warn "    Found $ELBV2_COUNT load balancer(s):"
    aws elbv2 describe-load-balancers \
        --query 'LoadBalancers[*].{Name:LoadBalancerName,Type:Type,State:State.Code,ARN:LoadBalancerArn}' \
        --output table 2>/dev/null || true
else
    log_info "    No ALB/NLB load balancers found."
fi

# Check Classic Load Balancers
log_info "  Classic Load Balancers (ELB):"
CLB_COUNT=$(aws elb describe-load-balancers --query 'LoadBalancerDescriptions | length(@)' --output text 2>/dev/null || echo "0")
if [[ "$CLB_COUNT" -gt 0 ]]; then
    log_warn "    Found $CLB_COUNT classic load balancer(s):"
    aws elb describe-load-balancers \
        --query 'LoadBalancerDescriptions[*].{Name:LoadBalancerName,DNSName:DNSName}' \
        --output table 2>/dev/null || true
else
    log_info "    No classic load balancers found."
fi

TOTAL_LBS=$((ELBV2_COUNT + CLB_COUNT))

log_info ""

# If check only, exit here
if [[ "$CHECK_ONLY" == "true" ]]; then
    if [[ "$TOTAL_LBS" -gt 0 ]]; then
        log_warn "Cannot delete service-linked role while $TOTAL_LBS load balancer(s) exist."
        log_info ""
        log_info "To delete load balancers:"
        log_info "  # Delete ALB/NLB"
        log_info "  aws elbv2 delete-load-balancer --load-balancer-arn <arn>"
        log_info ""
        log_info "  # Delete Classic LB"
        log_info "  aws elb delete-load-balancer --load-balancer-name <name>"
    else
        log_info "No load balancers found. Role can be deleted."
    fi
    exit 0
fi

# Check if there are load balancers
if [[ "$TOTAL_LBS" -gt 0 ]]; then
    log_error "Cannot delete service-linked role while load balancers exist!"
    log_error "Delete all load balancers first, then run this script again."
    log_info ""
    log_info "To delete load balancers via AWS CLI:"
    log_info ""
    
    if [[ "$ELBV2_COUNT" -gt 0 ]]; then
        log_info "  # List ALB/NLB ARNs"
        log_info "  aws elbv2 describe-load-balancers --query 'LoadBalancers[*].LoadBalancerArn' --output text"
        log_info ""
        log_info "  # Delete each ALB/NLB"
        log_info "  aws elbv2 delete-load-balancer --load-balancer-arn <arn>"
    fi
    
    if [[ "$CLB_COUNT" -gt 0 ]]; then
        log_info ""
        log_info "  # List Classic LB names"
        log_info "  aws elb describe-load-balancers --query 'LoadBalancerDescriptions[*].LoadBalancerName' --output text"
        log_info ""
        log_info "  # Delete each Classic LB"
        log_info "  aws elb delete-load-balancer --load-balancer-name <name>"
    fi
    
    exit 1
fi

# Confirmation prompt
if [[ "$FORCE" != "true" ]]; then
    echo ""
    echo -e "${YELLOW}WARNING: You are about to delete the AWS Service-Linked Role for Elastic Load Balancing.${NC}"
    echo ""
    echo "This role is automatically created by AWS and is required to create load balancers."
    echo "AWS will recreate it automatically when you next create a load balancer."
    echo ""
    read -p "Are you sure you want to continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborted."
        exit 0
    fi
fi

# Delete the service-linked role
log_info "Deleting service-linked role: $ROLE_NAME"
DELETION_TASK_ID=$(aws iam delete-service-linked-role --role-name "$ROLE_NAME" \
    --query 'DeletionTaskId' --output text 2>&1) || {
    log_error "Failed to initiate role deletion."
    log_error "Error: $DELETION_TASK_ID"
    exit 1
}

log_info "Deletion initiated. Task ID: $DELETION_TASK_ID"
log_info ""
log_info "Waiting for deletion to complete..."

# Poll for deletion status
MAX_ATTEMPTS=30
ATTEMPT=0
while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
    ATTEMPT=$((ATTEMPT + 1))
    
    STATUS=$(aws iam get-service-linked-role-deletion-status \
        --deletion-task-id "$DELETION_TASK_ID" \
        --query 'Status' --output text 2>/dev/null || echo "UNKNOWN")
    
    case "$STATUS" in
        SUCCEEDED)
            log_info "Role deleted successfully!"
            break
            ;;
        FAILED)
            REASON=$(aws iam get-service-linked-role-deletion-status \
                --deletion-task-id "$DELETION_TASK_ID" \
                --query 'Reason' --output text 2>/dev/null || echo "Unknown reason")
            log_error "Role deletion failed: $REASON"
            exit 1
            ;;
        IN_PROGRESS|NOT_STARTED)
            echo -n "."
            sleep 2
            ;;
        *)
            log_warn "Unknown status: $STATUS"
            sleep 2
            ;;
    esac
done
echo ""

if [[ $ATTEMPT -ge $MAX_ATTEMPTS ]]; then
    log_warn "Deletion is taking longer than expected."
    log_info "Check status with:"
    log_info "  aws iam get-service-linked-role-deletion-status --deletion-task-id $DELETION_TASK_ID"
fi

log_info ""
log_info "================================"
log_info "Cleanup completed!"
log_info "================================"
log_info ""
log_info "Note: AWS will automatically recreate this role when you"
log_info "create a new load balancer (ALB, NLB, or Classic)."
