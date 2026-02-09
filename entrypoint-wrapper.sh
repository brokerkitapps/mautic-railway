#!/bin/bash
set -e

echo "[wrapper] Starting entrypoint wrapper..."
echo "[wrapper] DOCKER_MAUTIC_ROLE=${DOCKER_MAUTIC_ROLE}"

# Fix Apache MPM conflict: remove mpm_event/worker before Apache starts
rm -f /etc/apache2/mods-enabled/mpm_event.conf /etc/apache2/mods-enabled/mpm_event.load
rm -f /etc/apache2/mods-enabled/mpm_worker.conf /etc/apache2/mods-enabled/mpm_worker.load
echo "[wrapper] Apache MPM cleanup done"

# Railway: each service has its own filesystem, so cron/worker containers
# need a pre-populated local.php with site_url for the install check.
# Alias MAUTIC_DB_NAME -> MAUTIC_DB_DATABASE (template expects the latter).
export MAUTIC_DB_DATABASE="${MAUTIC_DB_DATABASE:-$MAUTIC_DB_NAME}"
echo "[wrapper] MAUTIC_DB_DATABASE=${MAUTIC_DB_DATABASE}"
echo "[wrapper] MAUTIC_DB_HOST=${MAUTIC_DB_HOST}"

# Pre-create local.php with site_url if it doesn't exist and MAUTIC_URL is set.
CONFIG_DIR="/var/www/html/config"
if [ -n "$MAUTIC_URL" ] && [ ! -f "$CONFIG_DIR/local.php" ]; then
    echo "[wrapper] Creating local.php with site_url=${MAUTIC_URL}"
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/local.php" <<LOCALPHP
<?php
\$parameters = array(
    'db_driver' => 'pdo_mysql',
    'db_host' => '${MAUTIC_DB_HOST}',
    'db_port' => '${MAUTIC_DB_PORT:-3306}',
    'db_name' => '${MAUTIC_DB_DATABASE}',
    'db_user' => '${MAUTIC_DB_USER}',
    'db_password' => '${MAUTIC_DB_PASSWORD}',
    'db_table_prefix' => null,
    'db_backup_tables' => 1,
    'db_backup_prefix' => 'bak_',
    'site_url' => '${MAUTIC_URL}',
);
LOCALPHP
    chown www-data:www-data "$CONFIG_DIR/local.php"
    echo "[wrapper] local.php created successfully"
fi

# Also inject site_url into existing local.php
if [ -n "$MAUTIC_URL" ] && [ -f "$CONFIG_DIR/local.php" ]; then
    if ! grep -q "'site_url'" "$CONFIG_DIR/local.php"; then
        sed -i "s|);|    'site_url' => '${MAUTIC_URL}',\n);|" "$CONFIG_DIR/local.php"
        echo "[wrapper] Injected site_url into existing local.php"
    else
        echo "[wrapper] local.php already has site_url"
    fi
fi

echo "[wrapper] Calling original entrypoint..."
exec /entrypoint-original.sh "$@"
