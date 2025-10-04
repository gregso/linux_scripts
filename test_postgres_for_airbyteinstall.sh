#!/bin/bash

echo "=== Testing Airbyte Database Configuration ==="
echo ""

# Disable pager for psql
export PAGER=

# 1. Test direct PostgreSQL connection from host
echo "1. Testing from host machine:"
PGPASSWORD=airbyte123 psql -h 172.17.0.1 -U airbyte -d db-airbyte -t -c "SELECT version();" 2>&1 | head -1
HOST_TEST=${PIPESTATUS[0]}

# 2. Test from Docker (simulating Kubernetes pod)
echo ""
echo "2. Testing from Docker container (simulates K8s pod):"
docker run --rm \
  -e PGPASSWORD=airbyte123 \
  postgres:13 \
  psql "postgresql://airbyte:airbyte123@172.17.0.1:5432/db-airbyte" \
  -t -c "SELECT 'Docker connection successful' as status;" 2>&1 | head -1
DOCKER_TEST=${PIPESTATUS[0]}

# 3. Test from Kind network (if Kind cluster exists)
if docker network ls | grep -q kind; then
  echo ""
  echo "3. Testing from Kind network:"
  docker run --rm \
    --network kind \
    -e PGPASSWORD=airbyte123 \
    postgres:13 \
    psql "postgresql://airbyte:airbyte123@172.17.0.1:5432/db-airbyte" \
    -t -c "SELECT 'Kind network connection successful' as status;" 2>&1 | head -1
  KIND_TEST=${PIPESTATUS[0]}
else
  echo ""
  echo "3. No Kind network found (will be created during install)"
  KIND_TEST=0
fi

# 4. Verify PostgreSQL configuration
echo ""
echo "4. Current PostgreSQL configuration:"
echo "   Listen addresses:"
sudo -u postgres psql -t -c "SHOW listen_addresses;" | xargs
echo ""
echo "   pg_hba.conf entries for airbyte:"
sudo grep airbyte /etc/postgresql/*/main/pg_hba.conf | grep -v "^#"

echo ""
echo "=== Test Results ==="
if [ $HOST_TEST -eq 0 ]; then
  echo "✅ Host connection: SUCCESS"
else
  echo "❌ Host connection: FAILED"
fi

if [ $DOCKER_TEST -eq 0 ]; then
  echo "✅ Docker connection: SUCCESS"
else
  echo "❌ Docker connection: FAILED"
fi

if [ $KIND_TEST -eq 0 ]; then
  echo "✅ Kind network: SUCCESS or not tested"
else
  echo "❌ Kind network: FAILED"
fi

echo ""
if [ $HOST_TEST -eq 0 ] && [ $DOCKER_TEST -eq 0 ]; then
  echo "✅ All tests passed! Your airbyte-values.yaml should work."
  echo ""
  echo "Proceed with:"
  echo "  abctl local install --values airbyte-values.yaml"
else
  echo "❌ Some tests failed. Check the errors above."
  echo ""
  echo "Common fixes:"
  echo "  1. Verify password: sudo -u postgres psql -c \"ALTER USER airbyte WITH PASSWORD 'airbyte123';\""
  echo "  2. Check pg_hba.conf has md5 auth for 172.17.0.0/16 and 172.18.0.0/16"
  echo "  3. Verify listen_addresses = '*' in postgresql.conf"
  echo "  4. Restart PostgreSQL: sudo systemctl restart postgresql"
fi