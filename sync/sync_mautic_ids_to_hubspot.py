#!/usr/bin/env python3
"""Sync Mautic contact IDs to HubSpot as a custom property.

Standalone version for Railway cron deployment. Queries Mautic API for
contacts with hubspot_contact_id set, then batch-updates HubSpot with
the reverse mapping (mautic_contact_id).

This enables Hooked webhook actions in HubSpot workflows to reference
the Mautic contact ID via {{contact.mautic_contact_id}}.

Railway cron runs this every 15 minutes with --incremental --skip-existing.

Environment variables (set on Railway service):
  HUBSPOT_PRIVATE_APP_ACCESS_TOKEN - HubSpot private app token
  MAUTIC_BASE_URL - Mautic instance URL (e.g., https://marketing.brokerkit.app)
  MAUTIC_USERNAME - Mautic API username
  MAUTIC_PASSWORD - Mautic API password
  SLACK_WEBHOOK_URL - (optional) Slack incoming webhook for failure/success alerts
"""

import logging
import os
import sys
import time

import requests

# Configure logging with timestamps for Railway log viewer
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

HUBSPOT_TOKEN = os.getenv("HUBSPOT_PRIVATE_APP_ACCESS_TOKEN", "")
MAUTIC_BASE_URL = os.getenv("MAUTIC_BASE_URL", "").rstrip("/")
MAUTIC_USERNAME = os.getenv("MAUTIC_USERNAME", "")
MAUTIC_PASSWORD = os.getenv("MAUTIC_PASSWORD", "")
SLACK_WEBHOOK_URL = os.getenv("SLACK_WEBHOOK_URL", "")

HUBSPOT_BATCH_SIZE = 100  # HubSpot batch update limit
MAUTIC_PAGE_SIZE = 100
HUBSPOT_RATE_LIMIT_DELAY = 0.12  # ~8 requests/sec to stay under 100/10s


def notify_slack(message: str) -> None:
    """Post a notification to Slack via webhook. Silently skips if not configured."""
    if not SLACK_WEBHOOK_URL:
        return
    try:
        requests.post(SLACK_WEBHOOK_URL, json={"text": message}, timeout=10)
    except Exception:
        logger.warning("Failed to send Slack notification")


def ensure_hubspot_property() -> bool:
    """Create mautic_contact_id property if it doesn't exist."""
    headers = {
        "Authorization": f"Bearer {HUBSPOT_TOKEN}",
        "Content-Type": "application/json",
    }

    resp = requests.get(
        "https://api.hubapi.com/crm/v3/properties/contacts/mautic_contact_id",
        headers=headers,
    )

    if resp.status_code == 200:
        logger.info("Property mautic_contact_id already exists")
        return True

    if resp.status_code == 404:
        resp = requests.post(
            "https://api.hubapi.com/crm/v3/properties/contacts",
            headers=headers,
            json={
                "name": "mautic_contact_id",
                "label": "Mautic Contact ID",
                "type": "number",
                "fieldType": "number",
                "groupName": "contactinformation",
                "description": "Mautic CRM contact ID for webhook integration",
            },
        )
        if resp.status_code == 201:
            logger.info("Created mautic_contact_id property")
            return True
        logger.error("Failed to create property: %d %s", resp.status_code, resp.text[:200])
        return False

    logger.error("Unexpected status checking property: %d", resp.status_code)
    return False


def get_existing_mautic_ids(hubspot_ids: list[str]) -> dict[str, str | None]:
    """Batch-check which HubSpot contacts already have mautic_contact_id."""
    headers = {
        "Authorization": f"Bearer {HUBSPOT_TOKEN}",
        "Content-Type": "application/json",
    }
    result: dict[str, str | None] = {}

    for i in range(0, len(hubspot_ids), HUBSPOT_BATCH_SIZE):
        batch = hubspot_ids[i : i + HUBSPOT_BATCH_SIZE]
        resp = requests.post(
            "https://api.hubapi.com/crm/v3/objects/contacts/batch/read",
            headers=headers,
            json={
                "properties": ["mautic_contact_id"],
                "inputs": [{"id": str(hid)} for hid in batch],
            },
        )
        if resp.status_code in (200, 207):
            for record in resp.json().get("results", []):
                hs_id = record.get("id")
                mautic_id = record.get("properties", {}).get("mautic_contact_id")
                result[hs_id] = mautic_id
        else:
            logger.warning("Batch read failed (%d)", resp.status_code)
            for hid in batch:
                result[str(hid)] = None
        time.sleep(HUBSPOT_RATE_LIMIT_DELAY)

    return result


def sync_batch_to_hubspot(updates: list[dict]) -> tuple[int, int]:
    """Send batch updates to HubSpot. Returns (success, fail) counts."""
    headers = {
        "Authorization": f"Bearer {HUBSPOT_TOKEN}",
        "Content-Type": "application/json",
    }
    success = 0
    fail = 0

    for i in range(0, len(updates), HUBSPOT_BATCH_SIZE):
        batch = updates[i : i + HUBSPOT_BATCH_SIZE]

        resp = requests.post(
            "https://api.hubapi.com/crm/v3/objects/contacts/batch/update",
            headers=headers,
            json={
                "inputs": [
                    {
                        "id": str(u["hubspot_id"]),
                        "properties": {"mautic_contact_id": str(u["mautic_id"])},
                    }
                    for u in batch
                ]
            },
        )

        if resp.status_code in (200, 207):
            data = resp.json()
            results = data.get("results", [])
            errors = data.get("errors", [])
            success += len(results)
            fail += len(errors)
            if errors:
                logger.warning("Batch partial failure: %d ok, %d errors", len(results), len(errors))
        else:
            fail += len(batch)
            logger.error("Batch update failed: %d %s", resp.status_code, resp.text[:200])

        time.sleep(HUBSPOT_RATE_LIMIT_DELAY)

    return success, fail


def incremental_sync(*, skip_existing: bool = False, since_minutes: int = 0) -> int:
    """Query Mautic for contacts with hubspot_contact_id, sync to HubSpot.

    Returns exit code: 0 for success, 1 for errors.
    """
    if since_minutes > 0:
        logger.info("Incremental mode: fetching contacts modified in last %d minutes", since_minutes)
    else:
        logger.info("Full scan mode: fetching all Mautic contacts")
    logger.info("Querying Mautic for contacts with hubspot_contact_id...")

    updates = []
    start = 0
    seen_ids: set[int] = set()

    while True:
        params: dict[str, str | int] = {
            "limit": MAUTIC_PAGE_SIZE,
            "start": start,
            "orderBy": "id",
            "orderByDir": "ASC",
        }
        if since_minutes > 0:
            params["search"] = f"dateModified:>=-{since_minutes}minutes"

        resp = requests.get(
            f"{MAUTIC_BASE_URL}/api/contacts",
            params=params,
            auth=(MAUTIC_USERNAME, MAUTIC_PASSWORD),
        )

        if resp.status_code != 200:
            logger.error("Mautic API error: %d", resp.status_code)
            return 1

        data = resp.json()
        contacts = data.get("contacts", {})

        if not contacts:
            break

        for cid, contact in contacts.items():
            mautic_id = int(cid)
            if mautic_id in seen_ids:
                continue
            seen_ids.add(mautic_id)

            fields = contact.get("fields", {}).get("all", {})
            hs_id = fields.get("hubspot_contact_id")

            if hs_id and str(hs_id).strip():
                updates.append(
                    {"hubspot_id": str(hs_id).strip(), "mautic_id": mautic_id}
                )

        start += MAUTIC_PAGE_SIZE
        if len(contacts) < MAUTIC_PAGE_SIZE:
            break

        if start % 1000 == 0:
            logger.info("Scanned %d contacts, found %d with HubSpot IDs", start, len(updates))

    logger.info("Found %d Mautic contacts with hubspot_contact_id", len(updates))

    if not updates:
        logger.info("Nothing to sync.")
        return 0

    if skip_existing:
        logger.info("Checking for existing mautic_contact_id values...")
        all_hs_ids = [u["hubspot_id"] for u in updates]
        existing = get_existing_mautic_ids(all_hs_ids)
        already_set = sum(1 for v in existing.values() if v)
        logger.info("%d already have mautic_contact_id, skipping", already_set)
        updates = [u for u in updates if not existing.get(str(u["hubspot_id"]))]
        logger.info("%d remaining to sync", len(updates))

    if not updates:
        logger.info("Nothing to sync after filtering.")
        return 0

    logger.info("Syncing %d contacts...", len(updates))
    success, fail = sync_batch_to_hubspot(updates)

    logger.info("Results: success=%d, failed=%d, total=%d", success, fail, success + fail)

    if fail > 0:
        notify_slack(
            f":x: mautic-id-sync failed: {success} synced, {fail} failed"
        )
        return 1

    if success > 0:
        notify_slack(
            f":white_check_mark: mautic-id-sync: {success} contacts synced successfully"
        )

    return 0


def main() -> None:
    logger.info("=== Mautic ID -> HubSpot Sync (Railway Cron) ===")

    if not HUBSPOT_TOKEN:
        logger.error("HUBSPOT_PRIVATE_APP_ACCESS_TOKEN not set")
        notify_slack(":x: mautic-id-sync failed: HUBSPOT_PRIVATE_APP_ACCESS_TOKEN not set")
        sys.exit(1)

    if not MAUTIC_BASE_URL or not MAUTIC_USERNAME:
        logger.error("MAUTIC_BASE_URL, MAUTIC_USERNAME, MAUTIC_PASSWORD required")
        notify_slack(":x: mautic-id-sync failed: Mautic credentials not set")
        sys.exit(1)

    if not ensure_hubspot_property():
        notify_slack(":x: mautic-id-sync failed: could not ensure HubSpot property")
        sys.exit(1)

    exit_code = incremental_sync(skip_existing=True, since_minutes=20)

    logger.info("=== Sync complete (exit code: %d) ===", exit_code)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
