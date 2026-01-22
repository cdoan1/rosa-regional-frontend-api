#!/bin/bash
#
# Script to create an IAM role for EKS IRSA (IAM Roles for Service Accounts)
# for the rosa-regional-frontend-api service.
#
# Prerequisites:
#   - AWS CLI configured with appropriate permissions
#   - eksctl or kubectl access to EKS cluster
#   - jq installed
#
# Usage:
#   ./create-irsa-role.sh --cluster-name <eks-cluster-name> --region <aws-region>
#
# Example:
#   ./create-irsa-role.sh --cluster-name my-eks-cluster --region us-east-1
#

set -euo pipefail

# Default values
ROLE_NAME="rosa-regional-frontend-api-role"
NAMESPACE="rosa-regional-frontend"
SERVICE_ACCOUNT="rosa-regional-frontend-api"
DYNAMODB_TABLE="rosa-customer-accounts"
CLUSTER_NAME=""
REGION=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    cat << EOF
Usage: $0 --cluster-name <eks-cluster-name> --region <aws-region> [OPTIONS]

Required:
  --cluster-name    Name of the EKS cluster
  --region          AWS region where the cluster is located

Optional:
  --role-name       IAM role name (default: rosa-regional-frontend-api-role)
  --namespace       Kubernetes namespace (default: rosa-regional-frontend)
  --service-account Service account name (default: rosa-regional-frontend-api)
  --dynamodb-table  DynamoDB table name (default: rosa-customer-accounts)
  --help            Show this help message

Example:
  $0 --cluster-name my-eks-cluster --region us-east-1
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --role-name)
            ROLE_NAME="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --service-account)
            SERVICE_ACCOUNT="$2"
            shift 2
            ;;
        --dynamodb-table)
            DYNAMODB_TABLE="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "$CLUSTER_NAME" ]]; then
    log_error "Missing required argument: --cluster-name"
    usage
fi

if [[ -z "$REGION" ]]; then
    log_error "Missing required argument: --region"
    usage
fi

# Check for required tools
for cmd in aws jq; do
    if ! command -v $cmd &> /dev/null; then
        log_error "$cmd is required but not installed."
        exit 1
    fi
done

log_info "Creating IRSA role for rosa-regional-frontend-api"
log_info "  Cluster: $CLUSTER_NAME"
log_info "  Region: $REGION"
log_info "  Role Name: $ROLE_NAME"
log_info "  Namespace: $NAMESPACE"
log_info "  Service Account: $SERVICE_ACCOUNT"

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log_info "AWS Account ID: $ACCOUNT_ID"

# Get OIDC provider URL for the EKS cluster
log_info "Getting OIDC provider for EKS cluster..."
OIDC_PROVIDER=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$REGION" \
    --query "cluster.identity.oidc.issuer" \
    --output text | sed 's|https://||')

if [[ -z "$OIDC_PROVIDER" ]]; then
    log_error "Failed to get OIDC provider. Make sure OIDC is enabled for your EKS cluster."
    log_info "To enable OIDC, run: eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --region $REGION --approve"
    exit 1
fi

log_info "OIDC Provider: $OIDC_PROVIDER"

# Check if OIDC provider is associated with IAM
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" &> /dev/null; then
    log_warn "OIDC provider not found in IAM. Creating..."
    
    # As of July 2023, AWS no longer validates OIDC thumbprints for EKS clusters
    # that use the AWS-managed OIDC provider (oidc.eks.<region>.amazonaws.com).
    # IAM uses its own library of trusted root CAs to validate the OIDC provider.
    # However, the CreateOpenIDConnectProvider API still requires a thumbprint parameter.
    # 
    # We can use any valid 40-character hex string as a placeholder.
    # AWS recommends using eksctl which handles this automatically.
    #
    # Reference: https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html
    
    # Method 1: Try eksctl first (recommended, works for private clusters)
    if command -v eksctl &> /dev/null; then
        log_info "Using eksctl to associate OIDC provider (recommended for private clusters)..."
        eksctl utils associate-iam-oidc-provider \
            --cluster "$CLUSTER_NAME" \
            --region "$REGION" \
            --approve
        log_info "OIDC provider created via eksctl."
    else
        # Method 2: Try to extract thumbprint via openssl (requires network access to OIDC endpoint)
        log_info "eksctl not found, attempting to extract thumbprint via openssl..."
        OIDC_HOST=$(echo "${OIDC_PROVIDER}" | cut -d'/' -f1)
        
        THUMBPRINT=$(openssl s_client -servername "${OIDC_HOST}" -showcerts -connect "${OIDC_HOST}:443" </dev/null 2>/dev/null | \
            awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/{print}' | \
            tail -n +1 | \
            openssl x509 -fingerprint -sha1 -noout 2>/dev/null | \
            sed 's/.*=//;s/://g' | \
            tr '[:upper:]' '[:lower:]')
        
        if [[ -n "$THUMBPRINT" && ${#THUMBPRINT} -eq 40 ]]; then
            log_info "Extracted thumbprint: $THUMBPRINT"
            aws iam create-open-id-connect-provider \
                --url "https://${OIDC_PROVIDER}" \
                --client-id-list sts.amazonaws.com \
                --thumbprint-list "$THUMBPRINT"
            log_info "OIDC provider created."
        else
            # Method 3: Use a placeholder thumbprint (AWS doesn't validate it for EKS OIDC)
            # This is the thumbprint of the Amazon Root CA 1, commonly used as a placeholder
            log_warn "Could not extract thumbprint. Using placeholder (AWS does not validate EKS OIDC thumbprints)..."
            THUMBPRINT="9e99a48a9960b14926bb7f3b02e22da2b0ab7280"
            
            aws iam create-open-id-connect-provider \
                --url "https://${OIDC_PROVIDER}" \
                --client-id-list sts.amazonaws.com \
                --thumbprint-list "$THUMBPRINT"
            log_info "OIDC provider created with placeholder thumbprint."
        fi
    fi
fi

# Create trust policy document
TRUST_POLICY=$(cat << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
                    "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT}"
                }
            }
        }
    ]
}
EOF
)

# Create IAM policy for DynamoDB access
POLICY_NAME="${ROLE_NAME}-policy"
POLICY_DOCUMENT=$(cat << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "DynamoDBTableAccess",
            "Effect": "Allow",
            "Action": [
                "dynamodb:GetItem",
                "dynamodb:PutItem",
                "dynamodb:UpdateItem",
                "dynamodb:DeleteItem",
                "dynamodb:Query",
                "dynamodb:Scan",
                "dynamodb:BatchGetItem",
                "dynamodb:BatchWriteItem",
                "dynamodb:DescribeTable"
            ],
            "Resource": [
                "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${DYNAMODB_TABLE}",
                "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${DYNAMODB_TABLE}/index/*"
            ]
        }
    ]
}
EOF
)

# Check if role already exists
if aws iam get-role --role-name "$ROLE_NAME" &> /dev/null; then
    log_warn "Role $ROLE_NAME already exists. Updating trust policy..."
    aws iam update-assume-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-document "$TRUST_POLICY"
else
    log_info "Creating IAM role: $ROLE_NAME"
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --description "IAM role for rosa-regional-frontend-api EKS service account"
fi

# Check if policy already exists
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
if aws iam get-policy --policy-arn "$POLICY_ARN" &> /dev/null; then
    log_warn "Policy $POLICY_NAME already exists. Creating new version..."
    
    # List policy versions and delete oldest if at limit (max 5 versions)
    VERSIONS=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)
    VERSION_COUNT=$(echo "$VERSIONS" | wc -w)
    
    if [[ $VERSION_COUNT -ge 4 ]]; then
        OLDEST_VERSION=$(echo "$VERSIONS" | awk '{print $NF}')
        log_info "Deleting oldest policy version: $OLDEST_VERSION"
        aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST_VERSION"
    fi
    
    aws iam create-policy-version \
        --policy-arn "$POLICY_ARN" \
        --policy-document "$POLICY_DOCUMENT" \
        --set-as-default
else
    log_info "Creating IAM policy: $POLICY_NAME"
    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document "$POLICY_DOCUMENT" \
        --description "DynamoDB access policy for rosa-regional-frontend-api"
fi

# Attach policy to role
log_info "Attaching policy to role..."
aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "$POLICY_ARN" 2>/dev/null || true

# Get the role ARN
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

log_info ""
log_info "=========================================="
log_info "IRSA role created successfully!"
log_info "=========================================="
log_info ""
log_info "Role ARN: $ROLE_ARN"
log_info ""
log_info "Next steps:"
log_info "1. Update deploy/kubernetes/serviceaccount.yaml with the role ARN:"
log_info "   eks.amazonaws.com/role-arn: $ROLE_ARN"
log_info ""
log_info "2. Deploy the application:"
log_info "   make deploy"
log_info ""
log_info "3. Verify the service account annotation:"
log_info "   kubectl get sa $SERVICE_ACCOUNT -n $NAMESPACE -o yaml"
