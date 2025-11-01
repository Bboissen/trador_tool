import asyncio
import logging
import os
import time
from typing import Optional

import lighter
from lighter.api_client import ApiClient
from lighter.api.order_api import OrderApi
from lighter.configuration import Configuration


def _parse_csv(env_key: str):
    raw = os.getenv(env_key, "")
    return [x.strip() for x in raw.split(",") if x.strip()]


def _parse_float(env_key: str, default: float) -> float:
    raw = os.getenv(env_key, "").strip()
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError:
        logging.getLogger("roundtrip").warning("Invalid float for %s: %s", env_key, raw)
        return default


def _parse_int(env_key: str, default: Optional[int] = None) -> Optional[int]:
    raw = os.getenv(env_key, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        logging.getLogger("roundtrip").warning("Invalid int for %s: %s", env_key, raw)
        return default


async def _infer_base_scale() -> int:
    # Minimal helper when no explicit decimals provided; keep a conservative default
    return 6


async def _get_size_decimals(order_api: OrderApi, market_id: int) -> Optional[int]:
    try:
        details = await asyncio.wait_for(order_api.order_book_details(market_id=market_id), timeout=5.0)
        for d in getattr(details, "order_book_details", []) or []:
            if getattr(d, "market_id", None) == market_id:
                return int(d.size_decimals)
    except Exception:
        return None
    return None


async def _get_ideal_price_integer(order_api: OrderApi, market_id: int, is_ask: bool) -> int:
    ob = await asyncio.wait_for(order_api.order_book_orders(market_id, 1), timeout=5.0)
    price_str = (ob.bids[0].price if is_ask else ob.asks[0].price)
    return int(price_str.replace(".", ""))


def _to_base_units(amount: float, scale: int) -> int:
    return int(round(amount * (10 ** scale)))


async def execute_roundtrip() -> None:
    logger = logging.getLogger("roundtrip")

    api_host = os.getenv("LIGHTER_API_HOST", "https://mainnet.zklighter.elliot.ai")
    private_key = os.getenv("LIGHTER_API_KEY_PRIVATE_KEY", "")
    account_index = _parse_int("LIGHTER_ACCOUNT_INDEX")
    api_key_index = _parse_int("LIGHTER_API_KEY_INDEX", 0) or 0

    if not private_key or account_index is None:
        raise RuntimeError("Missing LIGHTER_API_KEY_PRIVATE_KEY or LIGHTER_ACCOUNT_INDEX")

    market_ids_raw = _parse_csv("LIGHTER_REST_MARKET_IDS")
    if not market_ids_raw:
        raise RuntimeError("LIGHTER_REST_MARKET_IDS must include at least one market id")
    market_id = int(market_ids_raw[0])

    base_amount_human = _parse_float("LIGHTER_MARKET_ORDER_BASE_AMOUNT", 0.1)
    max_slippage = _parse_float("LIGHTER_MARKET_ORDER_MAX_SLIPPAGE", 0.02)
    delay_seconds = _parse_float("LIGHTER_MARKET_ORDER_DELAY_SECONDS", 10.0)

    logger.info("Preparing roundtrip on market %s for amount=%s max_slippage=%s delay=%ss", market_id, base_amount_human, max_slippage, delay_seconds)

    logger.info("Creating signer client for account_index=%s api_key_index=%s", account_index, api_key_index)
    client = lighter.SignerClient(
        url=api_host,
        private_key=private_key,
        account_index=account_index,
        api_key_index=api_key_index,
    )
    # SDK REST client for order book data
    rest_api_client = ApiClient(configuration=Configuration(host=api_host))
    order_api = OrderApi(api_client=rest_api_client)

    try:
        # Convert human amount to integer base units using provided or discovered decimals
        size_decimals = _parse_int("LIGHTER_SIZE_DECIMALS")
        if size_decimals is None:
            size_decimals = await _get_size_decimals(order_api, market_id)
        scale = size_decimals if size_decimals is not None else await _infer_base_scale()
        logger.info("Using size_decimals=%s to compute base units", scale)
        base_amount_units = _to_base_units(base_amount_human, scale)
        if base_amount_units <= 0:
            raise RuntimeError("Computed base amount units must be positive")

        # Open: BUY
        open_coi = int(time.time())
        ideal_price_buy = await _get_ideal_price_integer(order_api, market_id, is_ask=False)
        acceptable_price_buy = round(ideal_price_buy * (1 + max_slippage))
        logger.info("Submitting BUY market order (coi=%s, units=%s, max_px=%s)", open_coi, base_amount_units, acceptable_price_buy)
        _, open_tx, open_err = await client.create_market_order(
            market_index=market_id,
            client_order_index=open_coi,
            base_amount=base_amount_units,
            avg_execution_price=acceptable_price_buy,
            is_ask=False,
            reduce_only=False,
        )
        if open_err is not None:
            raise RuntimeError(f"Open order failed: {open_err}")
        logger.info("Open order sent: %s", open_tx)

        # Wait
        logger.info("Waiting %.1f seconds before closing position", delay_seconds)
        await asyncio.sleep(delay_seconds)

        # Close: SELL reduce-only
        close_coi = open_coi + 1
        ideal_price_sell = await _get_ideal_price_integer(order_api, market_id, is_ask=True)
        acceptable_price_sell = round(ideal_price_sell * (1 - max_slippage))
        logger.info("Submitting SELL reduce-only market order (coi=%s, units=%s, min_px=%s)", close_coi, base_amount_units, acceptable_price_sell)
        _, close_tx, close_err = await client.create_market_order(
            market_index=market_id,
            client_order_index=close_coi,
            base_amount=base_amount_units,
            avg_execution_price=acceptable_price_sell,
            is_ask=True,
            reduce_only=True,
        )
        if close_err is not None:
            raise RuntimeError(f"Close order failed: {close_err}")
        logger.info("Close order sent: %s", close_tx)

    except Exception:
        logger.exception("Roundtrip execution failed")
    finally:
        await client.close()
        try:
            await rest_api_client.close()
        except Exception:
            pass


async def _maybe_guard_and_run():
    enabled = os.getenv("LIGHTER_EXECUTE_ROUNDTRIP_TRADE", "false").lower() in {"1", "true", "yes"}
    if not enabled:
        logging.getLogger("roundtrip").info("LIGHTER_EXECUTE_ROUNDTRIP_TRADE is false; skipping roundtrip")
        return
    await execute_roundtrip()


def main() -> None:
    logging.basicConfig(
        level=getattr(logging, os.getenv("LIGHTER_LOG_LEVEL", "INFO").upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    asyncio.run(_maybe_guard_and_run())


if __name__ == "__main__":
    main()


