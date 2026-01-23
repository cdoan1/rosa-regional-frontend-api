# Argo CD Deployment

This directory contains an Argo CD Application manifest for deploying the ROSA Regional Frontend API using GitOps.

## Directory Structure

```
argocd/
├── README.md
└── templates/
    └── application.yaml      # Argo CD Application
```

## Prerequisites

1. **Argo CD installed** in your cluster
   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```

2. **Argo CD CLI** (optional but recommended)
   ```bash
   # macOS
   brew install argocd

   # Linux
   curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
   chmod +x argocd && sudo mv argocd /usr/local/bin/
   ```

3. **AWS Load Balancer Controller** installed (for NLB support)

4. **IRSA role** created for the application
   ```bash
   ./deploy/scripts/create-irsa-role.sh --cluster-name <cluster> --region <region>
   ```

## Quick Start

1. Edit `templates/application.yaml` and update:
   - `ACCOUNT_ID` in the IRSA role ARN
   - `config.dynamodbRegion` for your region
   - Any other environment-specific values

2. Apply the Application:
   ```bash
   kubectl apply -f argocd/templates/application.yaml
   ```

3. Monitor the deployment:
   ```bash
   argocd app get frontend-api
   argocd app sync frontend-api  # Manual sync if needed
   ```

## Configuration

### Using the Application Template

The `application.yaml` template includes commonly used parameters:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `image.repository` | Container image repository | `quay.io/openshift-online/rosa-regional-frontend-api` |
| `image.tag` | Container image tag | `latest` |
| `serviceAccount.annotations.eks\.amazonaws\.com/role-arn` | IRSA role ARN | **Required** |
| `config.dynamodbRegion` | DynamoDB region | `us-east-2` |
| `config.dynamodbTable` | DynamoDB table name | `rosa-customer-accounts` |
| `loadBalancer.enabled` | Enable NLB | `true` |
| `loadBalancer.scheme` | NLB scheme | `internal` |
| `replicaCount` | Number of replicas | `2` |
| `autoscaling.enabled` | Enable HPA | `true` |

### Private Git Repository

If your repository is private, configure Argo CD with credentials:

```bash
# Using Argo CD CLI
argocd repo add https://github.com/openshift-online/rosa-regional-frontend-api.git \
  --username <username> \
  --password <github-token>
```

Or create a Secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: rosa-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/openshift-online/rosa-regional-frontend-api.git
  username: <username>
  password: <github-token>
```

## Sync Policies

### Automated Sync

The templates are configured with automated sync:

- **Prune**: Resources deleted from Git are removed from the cluster
- **Self-Heal**: Drift from desired state is automatically corrected
- **Retry**: Failed syncs are retried with exponential backoff

### Manual Sync

To disable automated sync, remove or comment out the `automated` section:

```yaml
syncPolicy:
  # automated:
  #   prune: true
  #   selfHeal: true
  syncOptions:
    - CreateNamespace=true
```

Then sync manually:

```bash
argocd app sync frontend-api
```

## Monitoring

### Argo CD UI

Access the Argo CD UI:

```bash
# Port forward
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Open https://localhost:8080
```

### CLI Commands

```bash
# List all applications
argocd app list

# Get application status
argocd app get frontend-api

# View application logs
argocd app logs frontend-api

# View sync history
argocd app history frontend-api

# Rollback to previous version
argocd app rollback frontend-api <revision>
```

## Troubleshooting

### Application Stuck in "Progressing"

Check the application events:
```bash
argocd app get frontend-api --show-operation
kubectl describe application frontend-api -n argocd
```

### Sync Failed

View sync details:
```bash
argocd app sync frontend-api --dry-run
argocd app diff frontend-api
```

### Health Check Failed

Check pod status:
```bash
kubectl get pods -n rosa-regional-frontend
kubectl describe pod -n rosa-regional-frontend <pod-name>
kubectl logs -n rosa-regional-frontend <pod-name>
```

### Resource Out of Sync

Force a hard refresh:
```bash
argocd app get frontend-api --hard-refresh
argocd app sync frontend-api --force
```
