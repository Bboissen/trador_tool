#!/usr/bin/env python3
"""
Hyperliquid SDK Service
A containerized service providing REST and WebSocket connectivity to Hyperliquid DEX
"""

import json
import os
import sys
import time
import logging
from datetime import datetime

from hyperliquid.info import Info

from runtime_config import ensure_sdk_config, resolve_api_base_url

# Configure logging
LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO')
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    stream=sys.stdout
)
logger = logging.getLogger(__name__)


class HyperliquidService:
    """Hyperliquid SDK Service Manager"""
    
    def __init__(self):
        self.api_url = resolve_api_base_url()
        network_override = os.getenv('HYPERLIQUID_NETWORK', '').lower()
        self.testnet = network_override == 'testnet' or os.getenv('HYPERLIQUID_TESTNET', '').lower() == 'true'
        self.config_path = ensure_sdk_config(logger)
        self.account_address = self._load_account_address()
        skip_ws = os.getenv('HYPERLIQUID_SKIP_WS', 'false').lower() == 'true'

        # Initialize Info API (read-only)
        self.info = Info(self.api_url, skip_ws=skip_ws)
        
        logger.info(f"Hyperliquid Service initialized")
        logger.info(f"Network: {'Testnet' if self.testnet else 'Mainnet'}")
        logger.info(f"API URL: {self.api_url}")
        logger.info(f"Config path: {self.config_path}")
        if self.account_address:
            logger.info(f"Monitoring account: {self.account_address}")
        else:
            logger.warning("No account address configured; balance monitoring will be skipped.")

    def _load_account_address(self) -> str:
        try:
            with open(self.config_path, 'r', encoding='utf-8') as config_file:
                config = json.load(config_file)
        except (FileNotFoundError, json.JSONDecodeError) as err:
            logger.warning(f"Unable to load Hyperliquid config for account address: {err}")
            return ""

        address = (config.get('account_address') or "").strip()
        return address.lower()
    
    def get_exchange_status(self):
        """Get current exchange status"""
        try:
            meta = self.info.meta()
            universe = meta.get('universe', [])
            logger.info(f"Exchange has {len(universe)} active markets")
            return {
                'status': 'operational',
                'markets': len(universe),
                'timestamp': datetime.now().isoformat()
            }
        except Exception as e:
            logger.error(f"Error getting exchange status: {e}")
            return None
    
    def log_account_balances(self):
        """Log summary of perpetual and spot balances for the configured account."""
        if not self.account_address:
            logger.debug("Balance monitor skipped: account address not configured.")
            return

        try:
            perp_state = self.info.user_state(self.account_address)
            spot_state = self.info.spot_user_state(self.account_address)
        except Exception as exc:
            logger.error(f"Error fetching account balances: {exc}")
            return

        margin_summary = perp_state.get('marginSummary', {}) or {}
        account_value = margin_summary.get('accountValue')
        total_margin_used = margin_summary.get('totalMarginUsed')

        perp_positions = []
        for entry in perp_state.get('assetPositions') or []:
            position = entry.get('position') or {}
            coin = position.get('coin') or entry.get('coin')
            size = position.get('szi')
            if coin and self._is_nonzero(size):
                perp_positions.append(f"{coin}:{size}")

        spot_balances = []
        for balance in spot_state.get('balances') or []:
            coin = balance.get('coin') or balance.get('name') or balance.get('token')
            total = balance.get('total') or balance.get('sz') or balance.get('balance') or balance.get('available')
            if coin and self._is_nonzero(total):
                spot_balances.append(f"{coin}:{total}")

        perp_summary_bits = []
        if account_value:
            perp_summary_bits.append(f"equity={account_value}")
        if total_margin_used:
            perp_summary_bits.append(f"margin_used={total_margin_used}")
        if not perp_summary_bits:
            perp_summary_bits.append("equity=unknown")

        logger.info(
            "Perp balances (%s) | positions: %s",
            ", ".join(perp_summary_bits),
            self._format_list(perp_positions),
        )
        logger.info("Spot balances: %s", self._format_list(spot_balances))

    @staticmethod
    def _is_nonzero(value) -> bool:
        if value is None:
            return False
        try:
            return abs(float(value)) > 1e-12
        except (TypeError, ValueError):
            return bool(str(value).strip()) and str(value).strip() not in ("0", "0.0")

    @staticmethod
    def _format_list(entries, limit: int = 5) -> str:
        if not entries:
            return "none"
        head = entries[:limit]
        formatted = ", ".join(head)
        if len(entries) > limit:
            formatted += ", ..."
        return formatted

    def monitor_balances(self, interval: int = 60):
        """Continuously log perp and spot balances."""
        logger.info(f"Monitoring perp and spot balances every {interval}s")

        while True:
            try:
                self.log_account_balances()
                time.sleep(interval)
            except KeyboardInterrupt:
                logger.info("Received shutdown signal")
                break
            except Exception as exc:
                logger.error(f"Error in balance monitor loop: {exc}")
                time.sleep(interval)


def main():
    """Main entry point"""
    logger.info("=" * 60)
    logger.info("Hyperliquid SDK Service Starting")
    logger.info("=" * 60)
    
    try:
        # Initialize service
        service = HyperliquidService()
        
        # Run initial checks
        logger.info("Running initial system checks...")
        
        # Check exchange connectivity
        meta = service.info.meta()
        exchange_timestamp = meta.get('time') or meta.get('timestamp') or meta.get('serverTime')
        if exchange_timestamp:
            logger.info(f"✓ Exchange connectivity verified - Timestamp: {exchange_timestamp}")
        else:
            logger.info("✓ Exchange connectivity verified")
        
        # Get initial status
        status = service.get_exchange_status()
        if status:
            logger.info(f"✓ Exchange operational - {status['markets']} markets available")
        
        # Start monitoring
        balance_interval = int(os.getenv('BALANCE_MONITOR_INTERVAL', os.getenv('HEALTHCHECK_INTERVAL', '60')))
        logger.info("Starting balance monitor...")
        service.monitor_balances(interval=balance_interval)
        
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
