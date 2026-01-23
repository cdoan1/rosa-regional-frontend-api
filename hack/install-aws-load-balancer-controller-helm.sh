#!/bin/bash
# =============================================================================
# AWS Load Balancer Controller - Helm Installation Script (Step 2 of 2)
#
# This script installs the AWS Load Balancer Controller via Helm.
# Run this from INSIDE the VPC (e.g., bastion host via SSM).
#
# Prerequisites:
#   - kubectl configured to access the EKS cluster
#   - helm v3 installed
#   - IAM resources created (run install-aws-load-balancer-controller.sh first)
#
# Usage:
#   ./install-aws-load-balancer-controller-helm.sh [options]
#
# Required Options:
#   --cluster-name NAME     EKS cluster name
#   --vpc-id ID             VPC ID
#   --region REGION         AWS region
#
# Optional:
#   --dry-run               Show what would be done without making changes
#   --upgrade               Force upgrade even if already installed
#   --uninstall             Remove the Helm release
#
# Example:
#   ./install-aws-load-balancer-controller-helm.sh \
#     --cluster-name regional-x8k2 \
#     --vpc-id vpc-0123456789abcdef \
#     --region us-west-2
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# AWS Load Balancer Controller
# See releases: https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases
# Requires Kubernetes 1.22+ (compatible with EKS 1.34)
#
# Leave LBC_HELM_CHART_VERSION empty to install latest version
# Or pin to specific version: helm search repo eks/aws-load-balancer-controller --versions
LBC_VERSION="2.17.1"  # For display purposes only
LBC_HELM_CHART_VERSION=""  # Empty = install latest
LBC_NAMESPACE="kube-system"
LBC_SERVICE_ACCOUNT="aws-load-balancer-controller"

# Colors for output (with fallback for non-interactive shells)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

print_step() {
    echo -e "${YELLOW}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "  $1"
}

usage() {
    head -35 "$0" | grep -E "^#" | sed 's/^# //' | sed 's/^#//'
    exit 1
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

CLUSTER_NAME=""
VPC_ID=""
REGION=""
DRY_RUN=false
UPGRADE=false
UNINSTALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --vpc-id)
            VPC_ID="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --upgrade)
            UPGRADE=true
            shift
            ;;
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Validate required inputs
# -----------------------------------------------------------------------------

print_header "Validating Configuration"

MISSING_ARGS=false

if [[ -z "$CLUSTER_NAME" ]]; then
    print_error "Cluster name is required (--cluster-name)"
    MISSING_ARGS=true
fi

if [[ -z "$VPC_ID" ]]; then
    print_error "VPC ID is required (--vpc-id)"
    MISSING_ARGS=true
fi

if [[ -z "$REGION" ]]; then
    print_error "Region is required (--region)"
    MISSING_ARGS=true
fi

if [[ "$MISSING_ARGS" == "true" ]]; then
    echo ""
    echo "Example:"
    echo "  $0 --cluster-name regional-x8k2 --vpc-id vpc-abc123 --region us-west-2"
    exit 1
fi

print_success "Cluster Name: $CLUSTER_NAME"
print_success "VPC ID: $VPC_ID"
print_success "Region: $REGION"

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo -e "${YELLOW}DRY RUN MODE - No changes will be made${NC}"
fi

# -----------------------------------------------------------------------------
# Prerequisite checks
# -----------------------------------------------------------------------------

print_header "Checking Prerequisites"

# Check kubectl
print_step "Checking kubectl..."
if ! command -v kubectl &>/dev/null; then
    print_error "kubectl not found"
    echo ""
    echo "Install kubectl:"
    echo "  curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""
    echo "  chmod +x kubectl && sudo mv kubectl /usr/local/bin/"
    exit 1
fi
KUBECTL_VERSION=$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion": "[^"]*"' | head -1 || echo "unknown")
print_success "kubectl found: $KUBECTL_VERSION"

# Check helm
print_step "Checking helm..."
if ! command -v helm &>/dev/null; then
    print_error "helm not found"
    echo ""
    echo "Install helm:"
    echo "  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    exit 1
fi
HELM_VERSION=$(helm version --short 2>/dev/null || echo "unknown")
print_success "helm found: $HELM_VERSION"

# Check cluster access
print_step "Checking kubectl cluster access..."
if ! kubectl cluster-info &>/dev/null; then
    print_error "Cannot connect to Kubernetes cluster"
    echo ""
    echo "Configure kubectl:"
    echo "  aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION"
    exit 1
fi
print_success "Cluster access verified"

# Verify we're connected to the right cluster
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "none")
print_info "Current context: $CURRENT_CONTEXT"

# -----------------------------------------------------------------------------
# Uninstall if requested
# -----------------------------------------------------------------------------

if [[ "$UNINSTALL" == "true" ]]; then
    print_header "Uninstalling AWS Load Balancer Controller"
    
    print_step "Checking for existing release..."
    if helm status aws-load-balancer-controller -n "$LBC_NAMESPACE" &>/dev/null; then
        print_step "Removing Helm release..."
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  Would run: helm uninstall aws-load-balancer-controller -n $LBC_NAMESPACE"
        else
            helm uninstall aws-load-balancer-controller -n "$LBC_NAMESPACE"
            print_success "Helm release removed"
        fi
    else
        print_info "No Helm release found"
    fi
    
    echo ""
    print_info "Note: IAM resources were NOT removed."
    print_info "To remove IAM resources, run from your local machine:"
    print_info "  ./scripts/install-aws-load-balancer-controller.sh --uninstall --from-terraform"
    
    print_success "Helm uninstallation complete"
    exit 0
fi

# -----------------------------------------------------------------------------
# Check if already installed
# -----------------------------------------------------------------------------

print_header "Checking Existing Installation"

EXISTING_RELEASE=""
if helm status aws-load-balancer-controller -n "$LBC_NAMESPACE" &>/dev/null; then
    EXISTING_RELEASE="found"
    CURRENT_VERSION=$(helm list -n "$LBC_NAMESPACE" -o json 2>/dev/null | \
        grep -o '"app_version":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
    print_info "AWS Load Balancer Controller is already installed"
    print_info "Current version: $CURRENT_VERSION"
    if [[ -n "$LBC_HELM_CHART_VERSION" ]]; then
        print_info "Target chart version: $LBC_HELM_CHART_VERSION"
    else
        print_info "Target version: latest"
    fi
    
    if [[ "$UPGRADE" != "true" ]]; then
        echo ""
        read -p "Do you want to upgrade? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted. Use --upgrade to force upgrade."
            exit 0
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Install/Upgrade AWS Load Balancer Controller
# -----------------------------------------------------------------------------

print_header "Installing AWS Load Balancer Controller"

print_step "Adding EKS Helm repository..."
if [[ "$DRY_RUN" == "true" ]]; then
    echo "  Would run: helm repo add eks https://aws.github.io/eks-charts"
else
    helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
    helm repo update eks
    print_success "Helm repository added/updated"
fi

if [[ -n "$LBC_HELM_CHART_VERSION" ]]; then
    print_step "Installing AWS Load Balancer Controller (chart v${LBC_HELM_CHART_VERSION})..."
else
    print_step "Installing AWS Load Balancer Controller (latest version)..."
fi

# Create values inline
HELM_VALUES=$(cat <<EOF
clusterName: ${CLUSTER_NAME}
region: ${REGION}
vpcId: ${VPC_ID}
serviceAccount:
  create: true
  name: ${LBC_SERVICE_ACCOUNT}
enableServiceMutatorWebhook: false
EOF
)

echo ""
echo "Helm values:"
echo "$HELM_VALUES" | sed 's/^/  /'
echo ""

# Build helm command with optional version flag
HELM_VERSION_FLAG=""
if [[ -n "$LBC_HELM_CHART_VERSION" ]]; then
    HELM_VERSION_FLAG="--version $LBC_HELM_CHART_VERSION"
fi

if [[ "$DRY_RUN" == "true" ]]; then
    echo "  Would run: helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller $HELM_VERSION_FLAG"
else
    echo "$HELM_VALUES" | helm upgrade --install aws-load-balancer-controller \
        eks/aws-load-balancer-controller \
        --namespace "$LBC_NAMESPACE" \
        $HELM_VERSION_FLAG \
        --values - \
        --wait \
        --timeout 5m
    
    # Get the actual installed version
    INSTALLED_VERSION=$(helm list -n "$LBC_NAMESPACE" -o json 2>/dev/null | \
        grep -o '"app_version":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
    print_success "AWS Load Balancer Controller v${INSTALLED_VERSION} installed"
fi

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------

print_header "Verification"

if [[ "$DRY_RUN" == "true" ]]; then
    echo "  Would verify deployment is ready"
else
    print_step "Waiting for deployment to be ready..."
    if kubectl rollout status deployment/aws-load-balancer-controller \
        -n "$LBC_NAMESPACE" \
        --timeout=120s; then
        print_success "Deployment is ready"
    else
        print_error "Deployment not ready within timeout"
    fi
    
    echo ""
    print_step "Controller pods:"
    kubectl get pods -n "$LBC_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller
    
    echo ""
    print_step "Checking controller logs for errors..."
    ERRORS=$(kubectl logs -n "$LBC_NAMESPACE" \
        -l app.kubernetes.io/name=aws-load-balancer-controller \
        --tail=50 2>/dev/null | grep -iE "error|failed|unauthorized" | tail -5 || true)
    
    if [[ -n "$ERRORS" ]]; then
        print_error "Recent errors found in controller logs:"
        echo "$ERRORS" | while read -r line; do
            echo "    $line"
        done
        echo ""
        echo "Common issues:"
        echo "  - 'unauthorized': IAM Pod Identity association may be missing"
        echo "  - 'failed to assume role': Check IAM role trust policy"
    else
        print_success "No errors in controller logs"
    fi
    
    echo ""
    print_step "Verifying TargetGroupBinding CRD..."
    if kubectl get crd targetgroupbindings.elbv2.k8s.aws &>/dev/null; then
        print_success "TargetGroupBinding CRD is available"
    else
        print_error "TargetGroupBinding CRD not found"
    fi
    
    echo ""
    print_step "Verifying IngressClassParams CRD..."
    if kubectl get crd ingressclassparams.elbv2.k8s.aws &>/dev/null; then
        print_success "IngressClassParams CRD is available"
    else
        print_info "IngressClassParams CRD not found (optional)"
    fi
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

print_header "Installation Complete"

echo ""
print_success "AWS Load Balancer Controller v${LBC_VERSION} is installed!"
echo ""
echo "Next steps:"
echo ""
echo "1. Create a TargetGroupBinding to register pods with your target group:"
echo ""
echo "   apiVersion: elbv2.k8s.aws/v1beta1"
echo "   kind: TargetGroupBinding"
echo "   metadata:"
echo "     name: frontend-api"
echo "     namespace: <your-namespace>"
echo "   spec:"
echo "     serviceRef:"
echo "       name: <your-service>"
echo "       port: 8080"
echo "     targetGroupARN: <from terraform output api_target_group_arn>"
echo "     targetType: ip"
echo ""
echo "2. Verify with:"
echo "   kubectl get targetgroupbinding -A"
echo "   kubectl describe targetgroupbinding <name> -n <namespace>"
echo ""
echo "3. Check target registration in AWS:"
echo "   aws elbv2 describe-target-health --target-group-arn <arn> --region $REGION"
echo ""
