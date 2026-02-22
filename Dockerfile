FROM mautic/mautic:5.2.8-20250908-apache

# OPcache tuning: increase from defaults for Symfony/Mautic performance
# - memory_consumption: 128 -> 256 (Symfony recommendation, ~91MB currently used)
# - interned_strings_buffer: 8 -> 32 (default exhausted at 8MB with 4074 cached scripts)
# - max_accelerated_files: 10000 -> 20000 (Symfony recommendation, currently 4074 scripts)
# - revalidate_freq: 2 -> 60 (reduce filesystem stat() calls in Docker)
RUN printf '%s\n' \
    'opcache.memory_consumption=256' \
    'opcache.interned_strings_buffer=32' \
    'opcache.max_accelerated_files=20000' \
    'opcache.revalidate_freq=60' \
    > /usr/local/etc/php/conf.d/zzz-opcache-tuning.ini

# Fix broken GD extension: install missing libavif dependency
RUN apt-get update && apt-get install -y --no-install-recommends libavif-dev \
    && rm -rf /var/lib/apt/lists/*

# Ensure required directories exist (Railway doesn't honor Docker VOLUME declarations)
RUN mkdir -p /var/www/html/var/logs \
    /var/www/html/config \
    /var/www/html/docroot/media/files \
    /var/www/html/docroot/media/images \
    && chown -R www-data:www-data /var/www/html/var /var/www/html/config /var/www/html/docroot/media

# Add HubSpot fetchleads to cron template (syncs HubSpot contacts every 15 min)
RUN echo '3,18,33,48 * * * * php -d memory_limit=1024M /var/www/html/bin/console mautic:integration:fetchleads --integration=Hubspot --limit=200 > /tmp/stdout 2>&1' >> /templates/mautic_cron

# Fix: Enforce DNC (Do Not Contact) compliance on API email sends
# Mautic 5.x hardcodes ignoreDNC => true for POST /api/emails/{id}/contact/{id}/send,
# treating all API sends as transactional (bypasses unsubscribe list). We change this to
# false so the API respects DNC while keeping email_type as transactional (allows re-sends
# to the same contact across workflow runs). See V3 test in brokerboost plan doc.
RUN sed -i "s/'ignoreDNC'         => true/'ignoreDNC'         => false/" \
    /var/www/html/app/bundles/EmailBundle/Controller/Api/EmailApiController.php

# BrokerKit email theme for GrapesJS builder (MJML)
COPY themes/brokerkit /var/www/html/docroot/themes/brokerkit
RUN chown -R www-data:www-data /var/www/html/docroot/themes/brokerkit

# Custom entrypoint wrapper:
# 1. Fixes Apache MPM conflict (removes mpm_event at runtime)
# 2. Injects site_url into local.php for cron/worker containers (Railway has no shared volumes)
# 3. Aliases MAUTIC_DB_NAME -> MAUTIC_DB_DATABASE (template expects the latter)
RUN mv /entrypoint.sh /entrypoint-original.sh
COPY entrypoint-wrapper.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

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
ENV PHP_INI_VALUE_MEMORY_LIMIT='1024M'
