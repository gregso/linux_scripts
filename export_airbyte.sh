# 07b0de11-9a13-4472-bae0-80c390ef0472

# secret : miuwsVgmWIwUuTxzT0ddmyd9Z2FYEVe5

curl -X POST "http://localhost:8000/api/v1/workspaces/07b0de11-9a13-4472-bae0-80c390ef0472/export" \
  -H "Content-Type: application/json" \
  -d '{}' \
  --output airbyte_workspace_export.json

# get token:
curl -X POST "http://localhost:8000/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email": "gsowa@softsystem.pl", "password": "miuwsVgmWIwUuTxzT0ddmyd9Z2FYEVe5"}'