# AWS Load Balancer Controller Setup

This document describes the AWS Load Balancer Controller deployment for the `rosa-regional-frontend-api` service, including setup for private EKS clusters.

## Overview

The AWS Load Balancer Controller manages AWS Elastic Load Balancers (NLB/ALB) for Kubernetes services and ingresses. For the `rosa-regional-frontend-api`, we use an **internal Network Load Balancer (NLB)** to expose the API within the VPC.

## Architecture

### Network Flow Diagram

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                    Private VPC                                         │
│                                                                                        │
│   ┌─────────────────┐                                                                  │
│   │                 │                                                                  │
│   │  Bastion Host   │─────────┐                                                        │
│   │                 │         │                                                        │
│   └─────────────────┘         │                                                        │
│                               │                                                        │
│                               ▼                                                        │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐  │
│   │                        Internal Network Load Balancer                           │  │
│   │                                                                                 │  │
│   │   DNS: k8s-rosaregi-rosaregi-xxxxxxxx.elb.us-east-2.amazonaws.com               │  │
│   │   Scheme: internal                                                              │  │
│   │   Type: NLB with IP targets                                                     │  │
│   │                                                                                 │  │
│   │   Listeners:                                                                    │  │
│   │     Port 80 → Target Group (rosa-regional-frontend-api pods on port 8000)       │  │
│   │                                                                                 │  │
│   │   Health Check:                                                                 │  │
│   │     Protocol: HTTP                                                              │  │
│   │     Port: 8080                                                                  │  │
│   │     Path: /healthz                                                              │  │
│   └─────────────────────────────────────────────────────────────────────────────────┘  │
│                               │                                                        │
│                               │ (IP target mode - direct to pod IPs)                   │
│                               ▼                                                        │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐  │
│   │                              EKS Cluster                                        │  │
│   │                                                                                 │  │
│   │   ┌──────────────────────────────────────────────────────────────────────────┐  │  │
│   │   │                    Namespace: rosa-regional-frontend                     │  │  │
│   │   │                                                                          │  │  │
│   │   │   ┌─────────────────────┐    ┌─────────────────────┐                     │  │  │
│   │   │   │        Pod 1        │    │        Pod 2        │                     │  │  │
│   │   │   │                     │    │                     │                     │  │  │
│   │   │   │  rosa-regional-     │    │  rosa-regional-     │                     │  │  │
│   │   │   │  frontend-api       │    │  frontend-api       │                     │  │  │
│   │   │   │                     │    │                     │                     │  │  │
│   │   │   │  Ports:             │    │  Ports:             │                     │  │  │
│   │   │   │   8000 (API)        │    │   8000 (API)        │                     │  │  │
│   │   │   │   8080 (Health)     │    │   8080 (Health)     │                     │  │  │
│   │   │   │   9090 (Metrics)    │    │   9090 (Metrics)    │                     │  │  │
│   │   │   └─────────────────────┘    └─────────────────────┘                     │  │  │
│   │   │                                                                          │  │  │
│   │   │   Service: rosa-regional-frontend-api-lb (LoadBalancer)                  │  │  │
│   │   │   Service: rosa-regional-frontend-api (ClusterIP)                        │  │  │
│   │   └──────────────────────────────────────────────────────────────────────────┘  │  │
│   │                                                                                 │  │
│   │   ┌──────────────────────────────────────────────────────────────────────────┐  │  │
│   │   │                    Namespace: kube-system                                │  │  │
│   │   │                                                                          │  │  │
│   │   │   ┌─────────────────────────────────────────────────────────────────┐    │  │  │
│   │   │   │              AWS Load Balancer Controller                       │    │  │  │
│   │   │   │                                                                 │    │  │  │
│   │   │   │  • Watches Service resources with LoadBalancer type             │    │  │  │
│   │   │   │  • Creates/manages NLB in AWS                                   │    │  │  │
│   │   │   │  • Registers pod IPs as targets                                 │    │  │  │
│   │   │   │  • Uses IRSA for AWS API authentication                         │    │  │  │
│   │   │   └─────────────────────────────────────────────────────────────────┘    │  │  │
│   │   └──────────────────────────────────────────────────────────────────────────┘  │  │
│   └─────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                        │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐  │
│   │                           VPC Endpoints (Required)                              │  │
│   │                                                                                 │  │
│   │   • com.amazonaws.us-east-2.sts                    (IRSA token exchange)        │  │
│   │   • com.amazonaws.us-east-2.elasticloadbalancing   (NLB management)             │  │
│   │   • com.amazonaws.us-east-2.ec2                    (Subnet/SG discovery)        │  │
│   │                                                                                 │  │
│   └─────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                        │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### Controller Reconciliation Flow

```
┌─────────────────────┐
│  Service Created    │
│  (type: LoadBalancer│
│   with annotations) │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  AWS LB Controller  │
│  detects Service    │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐     ┌─────────────────────┐
│  Read annotations   │────▶│  Determine LB type  │
│  from Service       │     │  (NLB, scheme, etc) │
└─────────────────────┘     └──────────┬──────────┘
                                       │
                                       ▼
                            ┌─────────────────────┐
                            │  Discover subnets   │
                            │  (by VPC tags)      │
                            └──────────┬──────────┘
                                       │
                                       ▼
                            ┌─────────────────────┐
                            │  Create/Update NLB  │
                            │  via AWS API        │
                            └──────────┬──────────┘
                                       │
                                       ▼
                            ┌─────────────────────┐
                            │  Create Target Group│
                            │  Register Pod IPs   │
                            └──────────┬──────────┘
                                       │
                                       ▼
                            ┌─────────────────────┐
                            │  Update Service     │
                            │  status with LB DNS │
                            └─────────────────────┘
```

## Components

### Kubernetes Resources

| Resource | Namespace | Purpose |
|----------|-----------|---------|
| ServiceAccount | `kube-system` | Identity for controller with IRSA |
| ClusterRole | - | Permissions to watch Services, Ingresses, etc. |
| ClusterRoleBinding | - | Binds ClusterRole to ServiceAccount |
| Role | `kube-system` | Leader election permissions |
| RoleBinding | `kube-system` | Binds Role to ServiceAccount |
| Deployment | `kube-system` | Runs the controller |
| IngressClass | - | Defines ALB ingress class |
| CRDs | - | TargetGroupBinding, IngressClassParams |

### AWS Resources Created

| Resource | Type | Purpose |
|----------|------|---------|
| IAM Role | `aws-load-balancer-controller-role` | IRSA role for controller |
| IAM Policy | `AWSLoadBalancerControllerIAMPolicy` | Permissions for ELB, EC2, etc. |
| NLB | Network Load Balancer | Routes traffic to pods |
| Target Group | IP-based | Contains pod IP addresses |
| Security Group | (optional) | Controls NLB traffic |

## Prerequisites for Private EKS Clusters

### 1. VPC Endpoints

Private EKS clusters require VPC endpoints for the controller to communicate with AWS services:

| Endpoint Service | Required | Purpose |
|------------------|----------|---------|
| `com.amazonaws.<region>.sts` | Yes | IRSA token exchange |
| `com.amazonaws.<region>.elasticloadbalancing` | Yes | Create/manage NLB |
| `com.amazonaws.<region>.ec2` | Yes | Discover subnets, security groups |

**Check existing endpoints:**
```bash
VPC_ID=$(aws eks describe-cluster --name <cluster-name> --region <region> \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'VpcEndpoints[*].{Service:ServiceName,State:State}' --output table
```

**Create missing endpoints:**
```bash
aws ec2 create-vpc-endpoint \
  --vpc-id $VPC_ID \
  --service-name com.amazonaws.<region>.elasticloadbalancing \
  --vpc-endpoint-type Interface \
  --subnet-ids <subnet-id-1> <subnet-id-2> \
  --security-group-ids <security-group-id>
```

### 2. Subnet Tags

Subnets must be tagged for the controller to discover them:

| Load Balancer Type | Required Tag |
|--------------------|--------------|
| Internal NLB/ALB | `kubernetes.io/role/internal-elb = 1` |
| Internet-facing NLB/ALB | `kubernetes.io/role/elb = 1` |

**Tag private subnets for internal load balancers:**
```bash
# Get EKS subnet IDs
SUBNET_IDS=$(aws eks describe-cluster --name <cluster-name> --region <region> \
  --query 'cluster.resourcesVpcConfig.subnetIds' --output text)

# Tag each subnet
for SUBNET_ID in $SUBNET_IDS; do
  aws ec2 create-tags --resources $SUBNET_ID \
    --tags Key=kubernetes.io/role/internal-elb,Value=1
done
```

### 3. OIDC Provider

EKS cluster must have an OIDC provider for IRSA:

```bash
# Check if OIDC is enabled
aws eks describe-cluster --name <cluster-name> --region <region> \
  --query 'cluster.identity.oidc.issuer' --output text

# If not enabled, associate it
eksctl utils associate-iam-oidc-provider \
  --cluster <cluster-name> \
  --region <region> \
  --approve
```

## Deployment

### Step 1: Create IAM Role

```bash
./deploy/aws-load-balancer-controller/create-iam-role.sh \
  --cluster-name <cluster-name> \
  --region <region>
```

### Step 2: Update Kustomization

Edit `deploy/aws-load-balancer-controller/kustomization.yaml` and replace:

| Placeholder | Description | Example |
|-------------|-------------|---------|
| `ACCOUNT_ID` | AWS Account ID | `123456789012` |
| `CLUSTER_NAME` | EKS cluster name | `regional-hn46` |
| `VPC_ID` | VPC ID | `vpc-0abc123def456789` |
| `AWS_REGION` | AWS region | `us-east-2` |

**Get VPC ID:**
```bash
aws eks describe-cluster --name <cluster-name> --region <region> \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text
```

### Step 3: Apply CRDs

```bash
kubectl apply -f deploy/aws-load-balancer-controller/crds.yaml
```

### Step 4: Deploy Controller

```bash
kubectl apply -k deploy/aws-load-balancer-controller/
```

### Step 5: Verify Deployment

```bash
# Check controller is running
kubectl get deployment -n kube-system aws-load-balancer-controller

# Check logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -c controller -f
```

## Service Configuration

### Internal NLB Service Example

```yaml
apiVersion: v1
kind: Service
metadata:
  name: rosa-regional-frontend-api-lb
  namespace: rosa-regional-frontend
  annotations:
    # NLB with IP targets (required for Fargate, works with EC2)
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb-ip"
    # Internal scheme - accessible only within VPC
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"
    # Cross-zone load balancing
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
    # Health check configuration
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-path: /healthz
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-port: "8080"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: HTTP
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: rosa-regional-frontend-api
  ports:
    - name: api
      port: 80
      targetPort: 8000
      protocol: TCP
```

### Common Annotations

| Annotation | Values | Description |
|------------|--------|-------------|
| `aws-load-balancer-type` | `nlb-ip`, `external`, `nlb` | Load balancer type |
| `aws-load-balancer-scheme` | `internal`, `internet-facing` | Accessibility |
| `aws-load-balancer-nlb-target-type` | `ip`, `instance` | Target registration |
| `aws-load-balancer-cross-zone-load-balancing-enabled` | `true`, `false` | Cross-AZ balancing |
| `aws-load-balancer-healthcheck-path` | `/healthz` | Health check endpoint |
| `aws-load-balancer-healthcheck-port` | `8080` | Health check port |
| `aws-load-balancer-healthcheck-protocol` | `HTTP`, `HTTPS`, `TCP` | Health check protocol |

## Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| Service stuck in `Pending` | No subnets found | Tag subnets with `kubernetes.io/role/internal-elb=1` |
| `unable to resolve subnet` | Wrong subnet tags | Use `internal-elb` for internal, `elb` for internet-facing |
| Controller can't reach AWS | Missing VPC endpoints | Create endpoints for STS, ELB, EC2 |
| IRSA not working | OIDC not configured | Associate OIDC provider with cluster |
| Permission denied | IAM policy missing | Check IAM role has required permissions |

### Diagnostic Commands

```bash
# Check service events
kubectl describe svc -n rosa-regional-frontend rosa-regional-frontend-api-lb

# Check controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -c controller --tail=100

# Check if NLB was created in AWS
aws elbv2 describe-load-balancers --query 'LoadBalancers[?contains(LoadBalancerName, `rosa-regional`)]'

# Check target group health
aws elbv2 describe-target-health --target-group-arn <target-group-arn>

# Verify subnet tags
aws ec2 describe-subnets --subnet-ids <subnet-ids> \
  --query 'Subnets[*].{ID:SubnetId,Tags:Tags}'
```

### Testing the Load Balancer

```bash
# Get the NLB DNS name
NLB_DNS=$(kubectl get svc -n rosa-regional-frontend rosa-regional-frontend-api-lb \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Test from bastion host (must be in same VPC for internal NLB)
curl http://$NLB_DNS/api/v0/live
curl http://$NLB_DNS/api/v0/ready
```

## Security Considerations

### Network Security

- **Internal NLB**: Only accessible from within the VPC or peered VPCs
- **Security Groups**: NLB can optionally use security groups for additional control
- **Private Subnets**: Deploy NLB in private subnets without internet access

### IAM Security

- **IRSA**: Controller uses short-lived tokens, no long-term credentials
- **Least Privilege**: IAM policy scoped to ELB and EC2 actions only
- **Trust Policy**: Only the specific ServiceAccount can assume the role

## Files Reference

| File | Purpose |
|------|---------|
| `deploy/aws-load-balancer-controller/kustomization.yaml` | Kustomize config with patches |
| `deploy/aws-load-balancer-controller/serviceaccount.yaml` | ServiceAccount with IRSA |
| `deploy/aws-load-balancer-controller/clusterrole.yaml` | RBAC permissions |
| `deploy/aws-load-balancer-controller/clusterrolebinding.yaml` | ClusterRole binding |
| `deploy/aws-load-balancer-controller/role.yaml` | Leader election Role |
| `deploy/aws-load-balancer-controller/deployment.yaml` | Controller Deployment |
| `deploy/aws-load-balancer-controller/crds.yaml` | Custom Resource Definitions |
| `deploy/aws-load-balancer-controller/create-iam-role.sh` | IAM setup script |
| `deploy/kubernetes/service.yaml` | Service with NLB annotations |
