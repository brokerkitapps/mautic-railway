FROM mautic/mautic:5.2.8-20250908-apache

# Fix broken GD extension: install missing libavif dependency
RUN apt-get update && apt-get install -y --no-install-recommends libavif-dev \
    && rm -rf /var/lib/apt/lists/*

# Fix Apache MPM conflict: completely remove mpm_event and mpm_worker
# Must run AFTER apt-get install which can re-enable them
RUN rm -f /etc/apache2/mods-enabled/mpm_event.conf /etc/apache2/mods-enabled/mpm_event.load \
          /etc/apache2/mods-enabled/mpm_worker.conf /etc/apache2/mods-enabled/mpm_worker.load \
          /etc/apache2/mods-available/mpm_event.conf /etc/apache2/mods-available/mpm_event.load \
          /etc/apache2/mods-available/mpm_worker.conf /etc/apache2/mods-available/mpm_worker.load \
    && a2enmod mpm_prefork 2>&1 || true

# Ensure required directories exist (Railway doesn't honor Docker VOLUME declarations)
RUN mkdir -p /var/www/html/var/logs \
    /var/www/html/config \
    /var/www/html/docroot/media/files \
    /var/www/html/docroot/media/images \
    && chown -R www-data:www-data /var/www/html/var /var/www/html/config /var/www/html/docroot/media

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
