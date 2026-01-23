# rosa-frontend-api Helm Chart

A Helm chart for deploying the ROSA Regional Frontend API to Kubernetes/EKS.

## Prerequisites

- Kubernetes 1.23+
- Helm 3.0+
- AWS Load Balancer Controller (if using LoadBalancer service)
- IRSA configured for DynamoDB access

## Installation

### Basic Installation

```bash
# Add the chart repository (if published)
# helm repo add rosa https://example.com/charts

# Install with default values
helm install frontend-api ./helm/rosa-frontend-api \
  --namespace rosa-regional-frontend \
  --create-namespace
```

### Installation with IRSA

```bash
helm install frontend-api ./helm/rosa-frontend-api \
  --namespace rosa-regional-frontend \
  --create-namespace \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::123456789012:role/rosa-frontend-api-role \
  --set config.dynamodb.region=us-east-2 \
  --set config.dynamodb.tableName=rosa-customer-accounts
```

### Installation with Load Balancer

```bash
helm install frontend-api ./helm/rosa-frontend-api \
  --namespace rosa-regional-frontend \
  --create-namespace \
  --set loadBalancer.enabled=true \
  --set loadBalancer.scheme=internal \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::123456789012:role/rosa-frontend-api-role
```

### Installation for Production

```bash
helm install frontend-api ./helm/rosa-frontend-api \
  --namespace rosa-regional-frontend \
  --create-namespace \
  -f ./helm/rosa-frontend-api/values-production.yaml \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::123456789012:role/rosa-frontend-api-role
```

### Installation for Staging

```bash
helm install frontend-api ./helm/rosa-frontend-api \
  --namespace rosa-regional-frontend-staging \
  --create-namespace \
  -f ./helm/rosa-frontend-api/values-staging.yaml \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::123456789012:role/rosa-frontend-api-role
```

## Upgrading

```bash
helm upgrade frontend-api ./helm/rosa-frontend-api \
  --namespace rosa-regional-frontend \
  --set image.tag=v1.1.0
```

## Uninstalling

```bash
helm uninstall frontend-api --namespace rosa-regional-frontend
```

## Configuration

### Key Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `replicaCount` | Number of replicas | `2` |
| `image.repository` | Image repository | `quay.io/openshift/rosa-frontend-api` |
| `image.tag` | Image tag | `latest` |
| `serviceAccount.create` | Create service account | `true` |
| `serviceAccount.annotations` | Service account annotations (for IRSA) | `{}` |
| `config.logLevel` | Log level | `info` |
| `config.dynamodb.region` | DynamoDB region | `us-east-1` |
| `config.dynamodb.tableName` | DynamoDB table name | `rosa-customer-accounts` |
| `config.maestroUrl` | Maestro service URL | `http://maestro:8000` |
| `loadBalancer.enabled` | Enable LoadBalancer service | `false` |
| `loadBalancer.scheme` | LB scheme (internal/internet-facing) | `internal` |
| `autoscaling.enabled` | Enable HPA | `true` |
| `autoscaling.minReplicas` | Minimum replicas | `2` |
| `autoscaling.maxReplicas` | Maximum replicas | `10` |

### Full Configuration

See [values.yaml](values.yaml) for all available configuration options.

## IRSA Configuration

The API requires AWS IAM permissions to access DynamoDB. Use IRSA (IAM Roles for Service Accounts) to provide these credentials securely.

### 1. Create the IAM Role

```bash
# Use the provided script
./deploy/scripts/create-irsa-role.sh \
  --cluster-name my-eks-cluster \
  --region us-east-2
```

### 2. Configure the Helm Release

```bash
helm install frontend-api ./helm/rosa-frontend-api \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::123456789012:role/rosa-frontend-api-role
```

## Load Balancer Configuration

To expose the API via an AWS Network Load Balancer (NLB), you need to complete the following setup.

### Prerequisites for NLB

#### 1. Install AWS Load Balancer Controller

The AWS Load Balancer Controller must be installed in your EKS cluster:

```bash
# Add the EKS Helm repo
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Create IAM policy for the controller
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

# Create IAM role for the controller (using eksctl)
eksctl create iamserviceaccount \
  --cluster=<cluster-name> \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::<account-id>:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

# Install the controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=<cluster-name> \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=<region> \
  --set vpcId=<vpc-id>
```

#### 2. Tag Subnets for Load Balancer Discovery

The controller discovers subnets using tags. Tag your subnets appropriately:

**For Internal NLB (private subnets):**
```bash
# Get your VPC ID
VPC_ID=$(aws eks describe-cluster --name <cluster-name> --region <region> \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

# Get subnet IDs
SUBNET_IDS=$(aws eks describe-cluster --name <cluster-name> --region <region> \
  --query 'cluster.resourcesVpcConfig.subnetIds' --output text)

# Tag subnets for internal load balancers
for SUBNET_ID in $SUBNET_IDS; do
  aws ec2 create-tags --resources $SUBNET_ID \
    --tags Key=kubernetes.io/role/internal-elb,Value=1
done
```

**For Internet-facing NLB (public subnets):**
```bash
aws ec2 create-tags --resources <public-subnet-id> \
  --tags Key=kubernetes.io/role/elb,Value=1
```

#### 3. VPC Endpoints (for Private Clusters)

If your EKS cluster is fully private, ensure these VPC endpoints exist:

| Endpoint | Purpose |
|----------|---------|
| `com.amazonaws.<region>.elasticloadbalancing` | NLB management |
| `com.amazonaws.<region>.ec2` | Subnet/SG discovery |
| `com.amazonaws.<region>.sts` | IRSA authentication |

```bash
# Check existing endpoints
aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'VpcEndpoints[*].ServiceName' --output table
```

### Enable Load Balancer in Helm

Once prerequisites are met, enable the load balancer:

```yaml
# values.yaml or --set flags
loadBalancer:
  enabled: true
  type: "nlb-ip"
  scheme: "internal"  # or "internet-facing"
  port: 80
  annotations: {}
```

```bash
helm install frontend-api ./helm/rosa-regional-frontend-api \
  --namespace rosa-regional-frontend \
  --create-namespace \
  --set loadBalancer.enabled=true \
  --set loadBalancer.scheme=internal \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::<account-id>:role/rosa-regional-frontend-api-role
```

### Verify Load Balancer Creation

```bash
# Watch the service for EXTERNAL-IP
kubectl get svc -n rosa-regional-frontend -w

# Check for errors
kubectl describe svc -n rosa-regional-frontend frontend-api-rosa-regional-frontend-api-lb

# Check controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Once created, get the NLB DNS
NLB_DNS=$(kubectl get svc -n rosa-regional-frontend frontend-api-rosa-regional-frontend-api-lb \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "NLB DNS: $NLB_DNS"

# Test (from within VPC for internal NLB)
curl http://$NLB_DNS/api/v0/live
```

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| Service stuck in `Pending` | No tagged subnets | Tag subnets with `kubernetes.io/role/internal-elb=1` |
| `unable to resolve subnet` | Wrong tag for scheme | Use `internal-elb` for internal, `elb` for internet-facing |
| Controller not creating LB | Missing permissions | Check IAM policy attached to controller role |
| Timeout connecting to NLB | Private cluster, no VPC endpoints | Create required VPC endpoints |

## Health Checks

The API exposes health endpoints:

| Endpoint | Port | Description |
|----------|------|-------------|
| `/healthz` | 8080 | Liveness probe |
| `/readyz` | 8080 | Readiness probe |
| `/api/v0/live` | 8000 | API liveness |
| `/api/v0/ready` | 8000 | API readiness |

## Metrics

Prometheus metrics are exposed on port 9090 at `/metrics`.

To scrape metrics with Prometheus, add annotations:

```yaml
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9090"
  prometheus.io/path: "/metrics"
```

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n rosa-regional-frontend -l app.kubernetes.io/name=rosa-frontend-api
```

### View Logs

```bash
kubectl logs -n rosa-regional-frontend -l app.kubernetes.io/name=rosa-frontend-api -f
```

### Check IRSA Configuration

```bash
# Verify service account annotation
kubectl get sa -n rosa-regional-frontend frontend-api-rosa-frontend-api -o yaml

# Check if AWS credentials are injected
kubectl exec -it <pod-name> -n rosa-regional-frontend -- env | grep AWS
```

### Test API

```bash
# Port forward
kubectl port-forward -n rosa-regional-frontend svc/frontend-api-rosa-frontend-api 8000:8000

# Test health
curl http://localhost:8000/api/v0/live
```
