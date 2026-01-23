# Helm Charts

This directory contains Helm charts for the ROSA Regional Frontend API.

## Available Charts

| Chart | Description |
|-------|-------------|
| `rosa-regional-frontend-api` | Deploy the ROSA Regional Frontend API |

## Installation Methods

### Method 1: Install Directly from Git Repository

You can install the chart directly from the Git repository without adding it as a Helm repo:

```bash
# Clone the repository
git clone https://github.com/openshift-online/rosa-regional-frontend-api.git
cd rosa-regional-frontend-api

# Install the chart
helm install frontend-api ./helm/rosa-regional-frontend-api \
  --namespace rosa-regional-frontend \
  --create-namespace
```

### Method 2: Install via Git URL (Helm 3.8+)

Helm 3.8+ supports installing charts directly from OCI registries and Git:

```bash
# Using helm-git plugin
helm plugin install https://github.com/aslafy-z/helm-git

# Install from Git
helm install frontend-api "git+https://github.com/openshift-online/rosa-regional-frontend-api@helm/rosa-regional-frontend-api?ref=main"
```

### Method 3: GitHub Pages Helm Repository

If the repository has GitHub Pages enabled with a Helm repository index:

```bash
# Add the Helm repository
helm repo add rosa https://openshift-online.github.io/rosa-regional-frontend-api

# Update repositories
helm repo update

# Search for charts
helm search repo rosa

# Install
helm install frontend-api rosa/rosa-regional-frontend-api \
  --namespace rosa-regional-frontend \
  --create-namespace
```

### Method 4: Argo CD Application

Deploy the Helm chart using Argo CD directly from the Git repository:

#### Option A: Argo CD Application Manifest

Create an Argo CD Application resource:

```yaml
# argocd/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: frontend-api
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/openshift-online/rosa-regional-frontend-api.git
    targetRevision: main  # or a specific tag/branch
    path: helm/rosa-regional-frontend-api
    helm:
      releaseName: frontend-api
      valueFiles:
        - values.yaml
        # - values-production.yaml  # for production overrides
      parameters:
        - name: image.tag
          value: "latest"
        - name: serviceAccount.annotations.eks\.amazonaws\.com/role-arn
          value: "arn:aws:iam::123456789012:role/rosa-regional-frontend-api-role"
        - name: config.dynamodbRegion
          value: "us-east-2"
        - name: loadBalancer.enabled
          value: "true"
  destination:
    server: https://kubernetes.default.svc
    namespace: rosa-regional-frontend
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Apply with:

```bash
kubectl apply -f argocd/application.yaml
```

#### Option B: Argo CD CLI

```bash
argocd app create frontend-api \
  --repo https://github.com/openshift-online/rosa-regional-frontend-api.git \
  --path helm/rosa-regional-frontend-api \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace rosa-regional-frontend \
  --sync-policy automated \
  --auto-prune \
  --self-heal \
  --helm-set image.tag=latest \
  --helm-set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::123456789012:role/rosa-regional-frontend-api-role \
  --helm-set config.dynamodbRegion=us-east-2 \
  --helm-set loadBalancer.enabled=true
```

#### Option C: ApplicationSet for Multiple Environments

Deploy to multiple clusters/environments using an ApplicationSet:

```yaml
# argocd/applicationset.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: frontend-api
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - env: staging
            cluster: https://staging-cluster.example.com
            awsAccount: "111111111111"
            region: us-east-1
          - env: production
            cluster: https://production-cluster.example.com
            awsAccount: "222222222222"
            region: us-west-2
  template:
    metadata:
      name: 'frontend-api-{{env}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/openshift-online/rosa-regional-frontend-api.git
        targetRevision: main
        path: helm/rosa-regional-frontend-api
        helm:
          releaseName: frontend-api
          valueFiles:
            - values.yaml
            - 'values-{{env}}.yaml'
          parameters:
            - name: serviceAccount.annotations.eks\.amazonaws\.com/role-arn
              value: 'arn:aws:iam::{{awsAccount}}:role/rosa-regional-frontend-api-role'
            - name: config.dynamodbRegion
              value: '{{region}}'
      destination:
        server: '{{cluster}}'
        namespace: rosa-regional-frontend
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

#### Private Git Repository

For private repositories, configure Argo CD with repository credentials:

```bash
# Add repository with HTTPS credentials
argocd repo add https://github.com/openshift-online/rosa-regional-frontend-api.git \
  --username <username> \
  --password <github-token>

# Or with SSH key
argocd repo add git@github.com:openshift-online/rosa-regional-frontend-api.git \
  --ssh-private-key-path ~/.ssh/id_rsa
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

### Method 5: OCI Registry (GitHub Container Registry)

Push the chart to GitHub Container Registry (ghcr.io):

```bash
# Package the chart
helm package ./helm/rosa-regional-frontend-api

# Login to GHCR
echo $GITHUB_TOKEN | helm registry login ghcr.io -u $GITHUB_USER --password-stdin

# Push to GHCR
helm push rosa-regional-frontend-api-0.1.0.tgz oci://ghcr.io/openshift-online

# Install from OCI registry
helm install frontend-api oci://ghcr.io/openshift-online/rosa-regional-frontend-api \
  --version 0.1.0 \
  --namespace rosa-regional-frontend \
  --create-namespace
```

## Setting Up GitHub Pages Helm Repository

To host the Helm chart on GitHub Pages:

### 1. Package the Chart

```bash
# Package the chart
helm package ./helm/rosa-regional-frontend-api -d ./docs

# Generate the index
helm repo index ./docs --url https://openshift-online.github.io/rosa-regional-frontend-api
```

### 2. Enable GitHub Pages

1. Go to repository Settings → Pages
2. Set Source to "Deploy from a branch"
3. Select the branch containing the `docs` folder (e.g., `main`)
4. Set folder to `/docs`

### 3. Automate with GitHub Actions

Create `.github/workflows/helm-release.yaml`:

```yaml
name: Release Helm Chart

on:
  push:
    tags:
      - 'helm-*'

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Configure Git
        run: |
          git config user.name "$GITHUB_ACTOR"
          git config user.email "$GITHUB_ACTOR@users.noreply.github.com"

      - name: Install Helm
        uses: azure/setup-helm@v3

      - name: Package Chart
        run: |
          mkdir -p docs
          helm package ./helm/rosa-regional-frontend-api -d ./docs

      - name: Update Index
        run: |
          if [ -f docs/index.yaml ]; then
            helm repo index ./docs --url https://openshift-online.github.io/rosa-regional-frontend-api --merge docs/index.yaml
          else
            helm repo index ./docs --url https://openshift-online.github.io/rosa-regional-frontend-api
          fi

      - name: Commit and Push
        run: |
          git add docs/
          git commit -m "Release Helm chart"
          git push
```

## Chart Development

### Lint the Chart

```bash
helm lint ./helm/rosa-regional-frontend-api
```

### Template Rendering (Debug)

```bash
helm template frontend-api ./helm/rosa-regional-frontend-api \
  --namespace rosa-regional-frontend \
  --debug
```

### Dry Run Installation

```bash
helm install frontend-api ./helm/rosa-regional-frontend-api \
  --namespace rosa-regional-frontend \
  --dry-run
```

### Package for Distribution

```bash
helm package ./helm/rosa-regional-frontend-api
# Creates: rosa-regional-frontend-api-0.1.0.tgz
```
