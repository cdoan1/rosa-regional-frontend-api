# IRSA Architecture for rosa-regional-frontend-api

This document describes the IAM Roles for Service Accounts (IRSA) architecture used by the `rosa-regional-frontend-api` to securely access AWS DynamoDB from within an EKS cluster.

## Overview

IRSA enables Kubernetes pods to assume AWS IAM roles without storing long-lived credentials. Instead, pods use short-lived tokens issued by the EKS OIDC provider.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                    AWS Account                                          │
│                                                                                         │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                              EKS Cluster                                          │  │
│  │                                                                                   │  │
│  │   ┌─────────────────────────────────────────────────────────────────────────┐    │  │
│  │   │                    Namespace: rosa-regional-frontend                     │    │  │
│  │   │                                                                          │    │  │
│  │   │   ┌──────────────────────────────────────────────────────────────────┐  │    │  │
│  │   │   │                          Pod                                      │  │    │  │
│  │   │   │                                                                   │  │    │  │
│  │   │   │   ┌─────────────────────────────────────────────────────────┐    │  │    │  │
│  │   │   │   │            rosa-regional-frontend-api                    │    │  │    │  │
│  │   │   │   │                   Container                              │    │  │    │  │
│  │   │   │   │                                                          │    │  │    │  │
│  │   │   │   │   ┌─────────────────────────────────────────────────┐   │    │  │    │  │
│  │   │   │   │   │  AWS SDK (aws-sdk-go-v2)                        │   │    │  │    │  │
│  │   │   │   │   │                                                  │   │    │  │    │  │
│  │   │   │   │   │  • Reads projected token from:                  │   │    │  │    │  │
│  │   │   │   │   │    /var/run/secrets/eks.amazonaws.com/          │   │    │  │    │  │
│  │   │   │   │   │    serviceaccount/token                         │   │    │  │    │  │
│  │   │   │   │   │                                                  │   │    │  │    │  │
│  │   │   │   │   │  • Uses AssumeRoleWithWebIdentity                │   │    │  │    │  │
│  │   │   │   │   └──────────────────────┬──────────────────────────┘   │    │  │    │  │
│  │   │   │   └──────────────────────────┼──────────────────────────────┘    │  │    │  │
│  │   │   │                              │                                    │  │    │  │
│  │   │   │   ServiceAccount: rosa-regional-frontend-api                     │  │    │  │
│  │   │   │   Annotation: eks.amazonaws.com/role-arn: <IAM_ROLE_ARN>         │  │    │  │
│  │   │   └──────────────────────────────┼───────────────────────────────────┘  │    │  │
│  │   └──────────────────────────────────┼──────────────────────────────────────┘    │  │
│  │                                      │                                           │  │
│  │   ┌──────────────────────────────────┼───────────────────────────────────────┐   │  │
│  │   │              EKS OIDC Provider   │                                        │   │  │
│  │   │   oidc.eks.<region>.amazonaws.com/id/<CLUSTER_ID>                        │   │  │
│  │   │                                  │                                        │   │  │
│  │   │   • Issues JWT tokens for pods   │                                        │   │  │
│  │   │   • Tokens contain:              │                                        │   │  │
│  │   │     - aud: sts.amazonaws.com     │                                        │   │  │
│  │   │     - sub: system:serviceaccount:│rosa-regional-frontend:                 │   │  │
│  │   │            rosa-regional-frontend-api                                     │   │  │
│  │   └──────────────────────────────────┼───────────────────────────────────────┘   │  │
│  └──────────────────────────────────────┼───────────────────────────────────────────┘  │
│                                         │                                              │
│                                         │ (1) AssumeRoleWithWebIdentity                │
│                                         │     + JWT Token                              │
│                                         ▼                                              │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                                 AWS STS                                           │  │
│  │                                                                                   │  │
│  │   • Validates JWT token against OIDC provider                                    │  │
│  │   • Checks trust policy conditions:                                              │  │
│  │     - aud == sts.amazonaws.com                                                   │  │
│  │     - sub == system:serviceaccount:rosa-regional-frontend:rosa-regional-...      │  │
│  │   • Returns temporary AWS credentials                                            │  │
│  └──────────────────────────────────────┬───────────────────────────────────────────┘  │
│                                         │                                              │
│                                         │ (2) Temporary Credentials                    │
│                                         │     (Access Key, Secret Key, Session Token)  │
│                                         ▼                                              │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                        IAM Role: rosa-regional-frontend-api-role                  │  │
│  │                                                                                   │  │
│  │   Trust Policy:                                                                  │  │
│  │   ┌────────────────────────────────────────────────────────────────────────┐     │  │
│  │   │  Principal: arn:aws:iam::<ACCOUNT>:oidc-provider/<OIDC_PROVIDER>       │     │  │
│  │   │  Action: sts:AssumeRoleWithWebIdentity                                 │     │  │
│  │   │  Condition:                                                            │     │  │
│  │   │    StringEquals:                                                       │     │  │
│  │   │      <OIDC>:aud: sts.amazonaws.com                                     │     │  │
│  │   │      <OIDC>:sub: system:serviceaccount:rosa-regional-frontend:         │     │  │
│  │   │                  rosa-regional-frontend-api                            │     │  │
│  │   └────────────────────────────────────────────────────────────────────────┘     │  │
│  │                                                                                   │  │
│  │   Attached Policy: rosa-regional-frontend-api-role-policy                        │  │
│  │   ┌────────────────────────────────────────────────────────────────────────┐     │  │
│  │   │  Actions:                                                              │     │  │
│  │   │    - dynamodb:GetItem         - dynamodb:Query                         │     │  │
│  │   │    - dynamodb:PutItem         - dynamodb:Scan                          │     │  │
│  │   │    - dynamodb:UpdateItem      - dynamodb:BatchGetItem                  │     │  │
│  │   │    - dynamodb:DeleteItem      - dynamodb:BatchWriteItem                │     │  │
│  │   │    - dynamodb:DescribeTable                                            │     │  │
│  │   │  Resources:                                                            │     │  │
│  │   │    - arn:aws:dynamodb:<REGION>:<ACCOUNT>:table/rosa-customer-accounts  │     │  │
│  │   │    - arn:aws:dynamodb:<REGION>:<ACCOUNT>:table/rosa-customer-.../index/*│     │  │
│  │   └────────────────────────────────────────────────────────────────────────┘     │  │
│  └──────────────────────────────────────┬───────────────────────────────────────────┘  │
│                                         │                                              │
│                                         │ (3) DynamoDB API calls                       │
│                                         │     with temporary credentials               │
│                                         ▼                                              │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                              AWS DynamoDB                                         │  │
│  │                                                                                   │  │
│  │   Table: rosa-customer-accounts                                                  │  │
│  │   ┌────────────────────────────────────────────────────────────────────────┐     │  │
│  │   │  Primary Key: account_id (String)                                      │     │  │
│  │   │                                                                         │     │  │
│  │   │  Stores customer account information for authorization                 │     │  │
│  │   └────────────────────────────────────────────────────────────────────────┘     │  │
│  └──────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

## Component Details

### 1. Kubernetes Components

| Component | Name | Purpose |
|-----------|------|---------|
| **Namespace** | `rosa-regional-frontend` | Isolates the application resources |
| **ServiceAccount** | `rosa-regional-frontend-api` | Identity for the pod, annotated with IAM role ARN |
| **Deployment** | `rosa-regional-frontend-api` | Runs the API pods with the service account |

### 2. AWS IAM Components

| Component | Name | Purpose |
|-----------|------|---------|
| **OIDC Provider** | `oidc.eks.<region>.amazonaws.com/id/<cluster-id>` | Enables EKS to issue tokens trusted by IAM |
| **IAM Role** | `rosa-regional-frontend-api-role` | Role assumed by the service account |
| **IAM Policy** | `rosa-regional-frontend-api-role-policy` | Grants DynamoDB access permissions |

### 3. AWS Services

| Service | Resource | Purpose |
|---------|----------|---------|
| **STS** | N/A | Exchanges JWT tokens for temporary credentials |
| **DynamoDB** | `rosa-customer-accounts` table | Stores customer account data |

## Authentication Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│    Pod      │     │  EKS OIDC   │     │   AWS STS   │     │  IAM Role   │     │  DynamoDB   │
│  (AWS SDK)  │     │  Provider   │     │             │     │             │     │             │
└──────┬──────┘     └──────┬──────┘     └──────┬──────┘     └──────┬──────┘     └──────┬──────┘
       │                   │                   │                   │                   │
       │  1. Read projected token              │                   │                   │
       │◄──────────────────│                   │                   │                   │
       │   (from /var/run/secrets/...)         │                   │                   │
       │                   │                   │                   │                   │
       │  2. AssumeRoleWithWebIdentity         │                   │                   │
       │──────────────────────────────────────►│                   │                   │
       │   (JWT token + role ARN)              │                   │                   │
       │                   │                   │                   │                   │
       │                   │  3. Validate token│                   │                   │
       │                   │◄──────────────────│                   │                   │
       │                   │   (verify signature)                  │                   │
       │                   │──────────────────►│                   │                   │
       │                   │   (token valid)   │                   │                   │
       │                   │                   │                   │                   │
       │                   │                   │  4. Check trust   │                   │
       │                   │                   │     policy        │                   │
       │                   │                   │──────────────────►│                   │
       │                   │                   │   (aud & sub match?)                  │
       │                   │                   │◄──────────────────│                   │
       │                   │                   │   (allowed)       │                   │
       │                   │                   │                   │                   │
       │  5. Temporary credentials             │                   │                   │
       │◄──────────────────────────────────────│                   │                   │
       │   (AccessKey, SecretKey, Token)       │                   │                   │
       │                   │                   │                   │                   │
       │  6. DynamoDB API call (GetItem, etc.) │                   │                   │
       │─────────────────────────────────────────────────────────────────────────────►│
       │   (signed with temp credentials)      │                   │                   │
       │                   │                   │                   │                   │
       │  7. Response (customer account data)  │                   │                   │
       │◄─────────────────────────────────────────────────────────────────────────────│
       │                   │                   │                   │                   │
```

## Setup Steps

### Prerequisites

1. EKS cluster with OIDC provider enabled
2. AWS CLI configured with appropriate permissions
3. `jq` installed

### Creating the IRSA Role

Run the setup script:

```bash
./deploy/scripts/create-irsa-role.sh \
  --cluster-name my-eks-cluster \
  --region us-east-1
```

The script performs these operations:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        create-irsa-role.sh                                  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  1. Get AWS Account ID                                                      │
│     aws sts get-caller-identity                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  2. Get OIDC Provider URL from EKS cluster                                  │
│     aws eks describe-cluster --name <cluster>                               │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  3. Create/Verify OIDC Provider in IAM (if not exists)                      │
│     aws iam create-open-id-connect-provider                                 │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  4. Create IAM Role with Trust Policy                                       │
│     aws iam create-role                                                     │
│                                                                             │
│     Trust Policy allows:                                                    │
│     • Principal: OIDC Provider                                              │
│     • Action: sts:AssumeRoleWithWebIdentity                                 │
│     • Condition: specific namespace/service account                         │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  5. Create IAM Policy for DynamoDB access                                   │
│     aws iam create-policy                                                   │
│                                                                             │
│     Permissions:                                                            │
│     • GetItem, PutItem, UpdateItem, DeleteItem                              │
│     • Query, Scan, BatchGetItem, BatchWriteItem                             │
│     • DescribeTable                                                         │
│     Resource: rosa-customer-accounts table + indexes                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  6. Attach Policy to Role                                                   │
│     aws iam attach-role-policy                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  7. Output Role ARN                                                         │
│     → Update serviceaccount.yaml with this ARN                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Post-Setup Configuration

1. **Update ServiceAccount annotation** in `deploy/kubernetes/serviceaccount.yaml`:

```yaml
metadata:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<ACCOUNT_ID>:role/rosa-regional-frontend-api-role
```

2. **Deploy the application**:

```bash
kubectl apply -k deploy/kubernetes/
```

3. **Verify the setup**:

```bash
# Check service account annotation
kubectl get sa rosa-regional-frontend-api -n rosa-regional-frontend -o yaml

# Check if pod has projected token
kubectl exec -it <pod-name> -n rosa-regional-frontend -- \
  ls -la /var/run/secrets/eks.amazonaws.com/serviceaccount/

# Verify pod can access DynamoDB
kubectl logs <pod-name> -n rosa-regional-frontend
```

## Security Considerations

### Principle of Least Privilege

- The IAM policy grants access **only** to the specific DynamoDB table needed
- Includes table indexes for query operations
- No wildcard permissions

### Trust Policy Restrictions

The trust policy ensures only the specific service account can assume the role:

| Condition | Value | Purpose |
|-----------|-------|---------|
| `aud` | `sts.amazonaws.com` | Ensures token is intended for AWS STS |
| `sub` | `system:serviceaccount:rosa-regional-frontend:rosa-regional-frontend-api` | Restricts to specific namespace and service account |

### Token Characteristics

- **Short-lived**: Tokens expire after ~1 hour (automatically refreshed)
- **Projected**: Mounted as a volume, not stored in secrets
- **Audience-bound**: Token is only valid for `sts.amazonaws.com`

## Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| `AccessDenied` when calling DynamoDB | IAM policy doesn't include required action | Update IAM policy |
| `InvalidIdentityToken` | OIDC provider not configured | Run `eksctl utils associate-iam-oidc-provider` |
| Pod can't assume role | Trust policy mismatch | Verify namespace/service account names match |
| Token not found | ServiceAccount not annotated | Add `eks.amazonaws.com/role-arn` annotation |

### Debugging Commands

```bash
# Check if OIDC provider exists
aws iam list-open-id-connect-providers

# Verify role trust policy
aws iam get-role --role-name rosa-regional-frontend-api-role

# Check attached policies
aws iam list-attached-role-policies --role-name rosa-regional-frontend-api-role

# Test DynamoDB access from pod
kubectl exec -it <pod> -n rosa-regional-frontend -- \
  aws dynamodb describe-table --table-name rosa-customer-accounts
```

## Related Files

| File | Purpose |
|------|---------|
| `deploy/scripts/create-irsa-role.sh` | Creates IAM role and policy |
| `deploy/kubernetes/serviceaccount.yaml` | ServiceAccount with IAM role annotation |
| `deploy/kubernetes/deployment.yaml` | Deployment using the service account |
| `pkg/clients/dynamodb/client.go` | Go client using AWS SDK with IRSA credentials |
