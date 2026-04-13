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
# Media dir is ephemeral here — entrypoint-wrapper.sh symlinks it to persistent config volume
RUN mkdir -p /var/www/html/var/logs \
    /var/www/html/config \
    /var/www/html/docroot/media/files \
    /var/www/html/docroot/media/images \
    && chown -R www-data:www-data /var/www/html/var /var/www/html/config /var/www/html/docroot/media

# Seed media directory with recovered images (lost when media had no persistent volume).
# On first deploy, entrypoint-wrapper.sh copies these into the persistent config volume.
COPY media/images/ /var/www/html/docroot/media/images/
RUN chown -R www-data:www-data /var/www/html/docroot/media/images

# Add HubSpot fetchleads to cron template (syncs HubSpot contacts every 15 min)
# Staggered to :08 to avoid overlap with segments:update (:00). Batch size 25
# (down from 50) to reduce peak memory per batch. 4 runs/hour = 100 contacts/hour throughput.
# Gets its own 2048M limit — the HubSpot plugin is inherently memory-hungry (OOMs at 1024M
# even with --limit=50). Safe because it runs at :08 when segments:update (:00) has finished.
RUN echo '8,23,38,53 * * * * php -d memory_limit=2048M /var/www/html/bin/console mautic:integration:fetchleads --integration=Hubspot --limit=25 > /tmp/stdout 2>&1' >> /templates/mautic_cron

# Clean up tracking data older than 2 years — runs daily at 02:01 UTC
# Deletes: audit_log, notifications, campaign_lead_event_log, page_hits, etc.
# Does NOT delete contacts, campaigns, or email templates.
RUN echo '1 2 * * * php /var/www/html/bin/console mautic:maintenance:cleanup --days-old=730 > /tmp/stdout 2>&1' >> /templates/mautic_cron

# Send scheduled segment/broadcast emails every 5 min at :02 offset (BK-3238)
# Without this, segment emails sit at "pending" indefinitely — only campaign emails
# (via campaigns:trigger) were working. --limit controls batch size per run;
# configurable at runtime via MAUTIC_BROADCAST_LIMIT env var (default 300).
# 300 × 12 runs/hr = 3,600 emails/hr → 8,700 contacts in ~2.5 hours.
RUN echo '2,7,12,17,22,27,32,37,42,47,52,57 * * * * php /var/www/html/bin/console mautic:broadcasts:send --limit=__BROADCAST_LIMIT__ > /tmp/stdout 2>&1' >> /templates/mautic_cron

# Update MaxMind GeoLite2 IP database weekly (Sundays at 04:00 UTC)
# Requires MaxMind license key configured in Mautic admin > IP Lookup Settings
RUN echo '0 4 * * 0 php /var/www/html/bin/console mautic:iplookup:download > /tmp/stdout 2>&1' >> /templates/mautic_cron

# Fix: Enforce DNC (Do Not Contact) compliance on API email sends
# Mautic 5.x hardcodes ignoreDNC => true for POST /api/emails/{id}/contact/{id}/send,
# treating all API sends as transactional (bypasses unsubscribe list). We change this to
# false so the API respects DNC while keeping email_type as transactional (allows re-sends
# to the same contact across workflow runs). See V3 test in brokerboost plan doc.
RUN sed -i "s/'ignoreDNC'         => true/'ignoreDNC'         => false/" \
    /var/www/html/docroot/app/bundles/EmailBundle/Controller/Api/EmailApiController.php \
    && grep -q "'ignoreDNC'         => false" \
    /var/www/html/docroot/app/bundles/EmailBundle/Controller/Api/EmailApiController.php

# BrokerKit email themes for GrapesJS builder (MJML)
COPY themes/brokerkit /var/www/html/docroot/themes/brokerkit
COPY themes/brokerkit-product-update /var/www/html/docroot/themes/brokerkit-product-update
COPY themes/brokerkit-newsletter /var/www/html/docroot/themes/brokerkit-newsletter
COPY themes/brokerkit-webinar /var/www/html/docroot/themes/brokerkit-webinar
COPY themes/brokerkit-brokerage-blueprint /var/www/html/docroot/themes/brokerkit-brokerage-blueprint
COPY themes/emma-brokerkit /var/www/html/docroot/themes/emma-brokerkit
RUN chown -R www-data:www-data /var/www/html/docroot/themes/brokerkit \
    /var/www/html/docroot/themes/brokerkit-product-update \
    /var/www/html/docroot/themes/brokerkit-newsletter \
    /var/www/html/docroot/themes/brokerkit-webinar \
    /var/www/html/docroot/themes/brokerkit-brokerage-blueprint \
    /var/www/html/docroot/themes/emma-brokerkit

# Fix MySQL 9.4+ error 1525 "Incorrect DATE value: ''" in segment filters
# empty/notEmpty operators compare date columns to '' which MySQL 9.4 rejects.
# Simplify to IS NULL / IS NOT NULL (safe: date cols can't store empty strings).
# Patches ComplexRelationValueFilterQueryBuilder + ForeignFuncFilterQueryBuilder.
# Upstream: https://github.com/mautic/mautic/issues/10686
COPY patches/fix_date_empty_filter.php /tmp/fix_date_empty_filter.php
RUN php /tmp/fix_date_empty_filter.php && rm /tmp/fix_date_empty_filter.php

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
# 512M per process — with 2 GB container, 3 concurrent cron jobs (1.5 GB) leaves
# ~500 MB for OS, cron daemon, and headroom. Was 1024M which caused OOM when
# segments:update overlapped with fetchleads or campaigns:update.
ENV PHP_INI_VALUE_MEMORY_LIMIT='512M'
