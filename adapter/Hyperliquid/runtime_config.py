"""Runtime helpers for configuring the Hyperliquid SDK container."""

from __future__ import annotations

import json
import logging
import os
from typing import Dict, List, Optional

from hyperliquid.utils import constants

DEFAULT_CONFIG_DIR = "/app/runtime"
DEFAULT_CONFIG_FILENAME = "config.json"
CONFIG_ENV_VARS = (
    "HYPERLIQUID_CONFIG_PATH",
    "HL_CONFIG_PATH",
)


def _first_present_env(*keys: str) -> str:
    for key in keys:
        value = os.getenv(key)
        if value:
            return value.strip()
    return ""


def resolve_api_base_url() -> str:
    """Determine the REST base URL, defaulting to testnet when requested."""
    network_override = os.getenv("HYPERLIQUID_NETWORK", "").lower()
    force_testnet = os.getenv("HYPERLIQUID_TESTNET", "").lower() == "true"
    if network_override == "testnet" or force_testnet:
        return _first_present_env(
            "HYPERLIQUID_TESTNET_API_URL",
            "HL_TESTNET_API_URL",
            "TESTNET_API_URL",
            "TESNET_API_URL",  # backwards compatibility with earlier typo
        ) or constants.TESTNET_API_URL

    # Default to mainnet when no override is present.
    return _first_present_env(
        "HYPERLIQUID_API_URL",
        "HYPERLIQUID_MAINNET_API_URL",
        "HL_MAINNET_API_URL",
        "MAINNET_API_URL",
    ) or constants.MAINNET_API_URL


def resolve_config_path() -> str:
    """Return the path where config.json should live."""
    for env_key in CONFIG_ENV_VARS:
        configured_path = os.getenv(env_key)
        if configured_path:
            return configured_path

    config_dir = os.getenv("HYPERLIQUID_CONFIG_DIR", DEFAULT_CONFIG_DIR)
    return os.path.join(config_dir, DEFAULT_CONFIG_FILENAME)


def _parse_authorized_users(raw_value: str, logger: Optional[logging.Logger]) -> List[Dict[str, str]]:
    if not raw_value:
        return []

    try:
        parsed = json.loads(raw_value)
    except json.JSONDecodeError:
        if logger:
            logger.warning("Unable to parse HYPERLIQUID_MULTI_SIG_USERS as JSON; skipping multi-sig entries.")
        return []

    if isinstance(parsed, list):
        return [entry for entry in parsed if isinstance(entry, dict)]

    if logger:
        logger.warning("Expected HYPERLIQUID_MULTI_SIG_USERS to be a JSON list; skipping multi-sig entries.")
    return []


def ensure_sdk_config(logger: Optional[logging.Logger] = None) -> str:
    """Create or refresh the Hyperliquid config.json based on environment variables."""
    config_path = resolve_config_path()
    config_dir = os.path.dirname(config_path)
    if config_dir:
        os.makedirs(config_dir, exist_ok=True)

    secret_key = _first_present_env(
        "HYPERLIQUID_PRIVATE_KEY",
        "HYPERLIQUID_API_PRIVATE_KEY",
        "HYPERLIQUID_TESTNET_PRIVATE_KEY",
        "HL_PRIVATE_KEY",
        "TESTNET_PRIVATE_KEY",
        "TESNET_PRIVATE_KEY",
    )
    account_address = _first_present_env(
        "HYPERLIQUID_ACCOUNT_ADDRESS",
        "HYPERLIQUID_TESTNET_ACCOUNT_ADDRESS",
        "HYPERLIQUID_PUBLIC_KEY",
        "HYPERLIQUID_API_PUBLIC_KEY",
        "HYPERLIQUID_TESTNET_PUBLIC_KEY",
        "HL_ACCOUNT_ADDRESS",
        "HL_PUBLIC_KEY",
        "TESTNET_PUBLIC_KEY",
        "TESNET_PUBLIC_KEY",
    )
    keystore_path = _first_present_env("HYPERLIQUID_KEYSTORE_PATH", "HL_KEYSTORE_PATH")
    multi_sig_raw = _first_present_env("HYPERLIQUID_MULTI_SIG_USERS", "HL_MULTI_SIG_USERS")

    config_payload = {
        "keystore_path": keystore_path,
        "secret_key": secret_key,
        "account_address": account_address,
        "multi_sig": {
            "authorized_users": _parse_authorized_users(multi_sig_raw, logger),
        },
    }

    fd = os.open(config_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as config_file:
        json.dump(config_payload, config_file, indent=2)
        config_file.write("\n")

    # Expose the resolved config path to any downstream code that relies on environment variables.
    os.environ["HYPERLIQUID_CONFIG_PATH"] = config_path
    os.environ["HL_CONFIG_PATH"] = config_path

    if logger:
        detail_bits = []
        if account_address:
            detail_bits.append("account address set")
        if secret_key:
            detail_bits.append("private key provided")
        if keystore_path and not secret_key:
            detail_bits.append("keystore path provided")
        if not detail_bits:
            logger.warning("Hyperliquid config.json created with placeholder credentials.")
        else:
            logger.info(
                "Hyperliquid config.json created (%s).",
                ", ".join(detail_bits),
            )

    return config_path


__all__ = [
    "ensure_sdk_config",
    "resolve_api_base_url",
    "resolve_config_path",
]
