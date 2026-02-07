#!/bin/bash
set -e

# Fix Apache MPM conflict: remove mpm_event/worker before Apache starts
rm -f /etc/apache2/mods-enabled/mpm_event.conf /etc/apache2/mods-enabled/mpm_event.load
rm -f /etc/apache2/mods-enabled/mpm_worker.conf /etc/apache2/mods-enabled/mpm_worker.load

# Railway: each service has its own filesystem, so cron/worker containers
# need site_url injected into local.php for the "is Mautic installed?" check.
# Also alias MAUTIC_DB_NAME -> MAUTIC_DB_DATABASE (template expects the latter).
export MAUTIC_DB_DATABASE="${MAUTIC_DB_DATABASE:-$MAUTIC_DB_NAME}"

if [ -n "$MAUTIC_URL" ] && [ -f /var/www/html/config/local.php ]; then
    # Add site_url if not already present
    if ! grep -q "'site_url'" /var/www/html/config/local.php; then
        sed -i "s|);|  'site_url' => '${MAUTIC_URL}',\n);|" /var/www/html/config/local.php
    fi
fi

exec /entrypoint-original.sh "$@"
