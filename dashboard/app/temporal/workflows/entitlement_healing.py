"""Scaffold only — next Temporal migrate after model sync + geoip.

Today entitlement healing lives in ``app.entitlements._healing_loop``.
When migrated, register ``EntitlementHealingWorkflow`` on the worker and
add a Schedule parallel to model-sync / geoip-mmdb. Do not import this
module from the worker until the activity exists.
"""
