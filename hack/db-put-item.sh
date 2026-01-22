aws dynamodb put-item \
  --table-name rosa-customer-accounts \
  --region us-east-2 \
  --item '{
    "account_id": {"S": "754250776154"},
    "privileged": {"BOOL": true},
    "created_at": {"S": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"},
    "updated_at": {"S": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}
  }'
