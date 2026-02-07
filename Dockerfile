FROM mautic/mautic:5.2.8-20250908-apache

# Fix broken GD extension: install missing libavif dependency
RUN apt-get update && apt-get install -y --no-install-recommends libavif-dev \
    && rm -rf /var/lib/apt/lists/*

# Ensure required directories exist (Railway doesn't honor Docker VOLUME declarations)
RUN mkdir -p /var/www/html/var/logs \
    /var/www/html/config \
    /var/www/html/docroot/media/files \
    /var/www/html/docroot/media/images \
    && chown -R www-data:www-data /var/www/html/var /var/www/html/config /var/www/html/docroot/media

# Fix Apache MPM conflict at runtime (build-time fixes get overwritten)
# This wrapper removes mpm_event before calling the original entrypoint
RUN mv /entrypoint.sh /entrypoint-original.sh \
    && printf '#!/bin/bash\nset -e\nrm -f /etc/apache2/mods-enabled/mpm_event.conf /etc/apache2/mods-enabled/mpm_event.load\nrm -f /etc/apache2/mods-enabled/mpm_worker.conf /etc/apache2/mods-enabled/mpm_worker.load\nexec /entrypoint-original.sh "$@"\n' > /entrypoint.sh \
    && chmod +x /entrypoint.sh

ARG MAUTIC_DB_HOST
ARG MAUTIC_DB_PORT
ARG MAUTIC_DB_USER
ARG MAUTIC_DB_PASSWORD
ARG MAUTIC_DB_NAME
ARG MAUTIC_TRUSTED_PROXIES
ARG MAUTIC_URL
ARG MAUTIC_ADMIN_EMAIL
ARG MAUTIC_ADMIN_PASSWORD

ENV MAUTIC_DB_HOST=$MAUTIC_DB_HOST
ENV MAUTIC_DB_PORT=$MAUTIC_DB_PORT
ENV MAUTIC_DB_USER=$MAUTIC_DB_USER
ENV MAUTIC_DB_PASSWORD=$MAUTIC_DB_PASSWORD
ENV MAUTIC_DB_NAME=$MAUTIC_DB_NAME
ENV MAUTIC_TRUSTED_PROXIES=$MAUTIC_TRUSTED_PROXIES
ENV MAUTIC_URL=$MAUTIC_URL
ENV MAUTIC_ADMIN_EMAIL=$MAUTIC_ADMIN_EMAIL
ENV MAUTIC_ADMIN_PASSWORD=$MAUTIC_ADMIN_PASSWORD
ENV PHP_INI_DATE_TIMEZONE='UTC'
