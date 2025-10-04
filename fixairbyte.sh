#!/bin/bash
# Fix PostgreSQL for Airbyte/Kubernetes access

echo "=== Fixing PostgreSQL for Airbyte Kubernetes Access ==="

# Find postgresql.conf
PG_CONF=$(sudo -u postgres psql -t -c "SHOW config_file;" | xargs)
HBA_CONF=$(sudo -u postgres psql -t -c "SHOW hba_file;" | xargs)

echo "PostgreSQL config: $PG_CONF"
echo "HBA config: $HBA_CONF"

# Backup
sudo cp "$PG_CONF" "${PG_CONF}.backup.$(date +%s)"
sudo cp "$HBA_CONF" "${HBA_CONF}.backup.$(date +%s)"

# 1. Make PostgreSQL listen on all interfaces
echo "Setting listen_addresses = '*'..."
sudo sed -i "s/^#*listen_addresses.*/listen_addresses = '*'/" "$PG_CONF"

# 2. Update pg_hba.conf to allow Kind network
echo "Updating pg_hba.conf for Kind network..."

# Remove old Airbyte entries if they exist
sudo sed -i '/# Kind\/Kubernetes networks for Airbyte/,+3d' "$HBA_CONF"

# Kind typically uses these networks:
# - 172.17.0.0/16 (Docker bridge)
# - 172.18.0.0/16 (Kind network)
# - 10.96.0.0/12 (Kubernetes service network)

sudo tee -a "$HBA_CONF" > /dev/null <<'EOF'

# Kind/Kubernetes networks for Airbyte
host    all             airbyte         172.17.0.0/16           md5
host    all             airbyte         172.18.0.0/16           md5
host    all             airbyte         10.96.0.0/12            md5
EOF

# 3. Restart PostgreSQL
echo "Restarting PostgreSQL..."
sudo systemctl restart postgresql
sleep 3

# 4. Verify
echo ""
echo "Verification:"
echo "PostgreSQL is listening on:"
sudo ss -tlnp | grep 5432
echo ""

# 5. Test connection from Docker network with password using connection string
echo "Testing connection from Docker network..."
docker run --rm \
  -e PGPASSWORD=airbyte123 \
  postgres:13 \
  psql "postgresql://airbyte:airbyte123@172.17.0.1:5432/airbyte" \
  -c "SELECT 'Success! PostgreSQL is accessible from Docker/Kubernetes' as status;" 2>&1

TEST_RESULT=$?

echo ""
if [ $TEST_RESULT -eq 0 ]; then
  echo "✅ SUCCESS! PostgreSQL is properly configured for Airbyte."
  echo ""
  echo "Next steps:"
  echo "  1. Ensure airbyte-values.yaml exists with correct settings"
  echo "  2. Run: abctl local install --values airbyte-values.yaml"
else
  echo "❌ FAILED! Connection test failed."
  echo ""
  echo "Debugging steps:"
  echo ""
  echo "1. Verify airbyte user password is set:"
  sudo -u postgres psql -c "ALTER USER airbyte WITH PASSWORD 'airbyte123';"
  echo ""
  echo "2. Check current pg_hba.conf entries for airbyte:"
  sudo grep airbyte "$HBA_CONF"
  echo ""
  echo "3. Verify listen_addresses:"
  sudo -u postgres psql -c "SHOW listen_addresses;"
  echo ""
  echo "4. Check PostgreSQL logs for connection attempts:"
  echo "   sudo journalctl -u postgresql -n 20 --no-pager"
fi

echo ""
echo "Your airbyte-values.yaml should contain:"
echo "---"
cat <<'YAML'
global:
  edition: community

postgresql:
  enabled: false

externalDatabase:
  host: "172.17.0.1"
  port: 5432
  database: "airbyte"
  user: "airbyte"
  password: "airbyte123"
YAML
echo "---"