from __future__ import annotations

import asyncio
import json
import logging
import os
import signal
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable, List, Optional

from lighter.api.root_api import RootApi
from lighter.api.account_api import AccountApi
from lighter.api.order_api import OrderApi
from lighter.api_client import ApiClient
from lighter.configuration import Configuration
from lighter.signer_client import SignerClient
from lighter.ws_client import WsClient
try:
    # When executed as a script from inside the app directory
    from roundtrip_trade import _maybe_guard_and_run as _roundtrip_maybe_run
except Exception:  # pragma: no cover - fallback for package-style execution
    # When executed via python -m from project root
    from app.roundtrip_trade import _maybe_guard_and_run as _roundtrip_maybe_run


DEFAULT_STATE_FILE = Path(os.getenv("LIGHTER_STATE_FILE", "/tmp/lighter_adapter/state.json"))
REST_INTERVAL_SECONDS = float(os.getenv("LIGHTER_REST_INTERVAL_SECONDS", "30"))
WS_RECONNECT_DELAY_SECONDS = float(os.getenv("LIGHTER_WS_RECONNECT_SECONDS", "5"))
DEFAULT_ROUNDTRIP_DELAY_SECONDS = 30.0



def _resolve_host(env_key: str, default: Optional[str]) -> Optional[str]:
    host = os.getenv(env_key)
    if host:
        return host
    return default


def _parse_csv(env_key: str) -> List[str]:
    raw = os.getenv(env_key, "")
    items = [item.strip() for item in raw.split(",") if item.strip()]
    return items


@dataclass
class HealthState:
    path: Path
    state: dict = field(default_factory=lambda: {
        "last_rest": None,
        "last_ws": None,
        "last_ws_channel": None,
    })

    def __post_init__(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.persist()

    def mark_rest(self) -> None:
        self.state["last_rest"] = time.time()
        self.persist()

    def mark_ws(self, channel: Optional[str]) -> None:
        self.state["last_ws"] = time.time()
        self.state["last_ws_channel"] = channel
        self.persist()

    def persist(self) -> None:
        tmp_path = self.path.with_suffix(".tmp")
        tmp_path.write_text(json.dumps(self.state), encoding="utf-8")
        tmp_path.replace(self.path)


def _parse_optional_int(env_key: str) -> Optional[int]:
    raw = os.getenv(env_key, "").strip()
    if not raw:
        return None
    try:
        return int(raw)
    except ValueError:
        logging.getLogger("config").warning("Invalid integer for %s: %s", env_key, raw)
    return None


def _parse_int_csv(env_key: str) -> List[int]:
    values: List[int] = []
    for item in _parse_csv(env_key):
        try:
            values.append(int(item))
        except ValueError:
            logging.getLogger("config").warning("Invalid integer in %s: %s", env_key, item)
    return values


def _parse_positive_float(env_key: str, default: float) -> float:
    raw = os.getenv(env_key, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        logging.getLogger("config").warning("Invalid float for %s: %s", env_key, raw)
        return default
    if value <= 0:
        logging.getLogger("config").warning("Non-positive value for %s: %s", env_key, raw)
        return default
    return value


def _parse_positive_int(env_key: str) -> Optional[int]:
    raw = os.getenv(env_key, "").strip()
    if not raw:
        return None
    try:
        value = int(raw)
    except ValueError:
        logging.getLogger("config").warning("Invalid integer for %s: %s", env_key, raw)
        return None
    if value <= 0:
        logging.getLogger("config").warning("Non-positive value for %s: %s", env_key, raw)
        return None
    return value


def _parse_non_negative_float(env_key: str, default: float) -> float:
    raw = os.getenv(env_key, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        logging.getLogger("config").warning("Invalid float for %s: %s", env_key, raw)
        return default
    if value < 0:
        logging.getLogger("config").warning("Negative value for %s: %s", env_key, raw)
        return default
    return value


def _parse_positive_number(env_key: str) -> Optional[float]:
    raw = os.getenv(env_key, "").strip()
    if not raw:
        return None
    try:
        value = float(raw)
    except ValueError:
        logging.getLogger("config").warning("Invalid number for %s: %s", env_key, raw)
        return None
    if value <= 0:
        logging.getLogger("config").warning("Non-positive value for %s: %s", env_key, raw)
        return None
    return value


@dataclass
class AuthTokenCache:
    signer: SignerClient
    ttl_seconds: float
    refresh_margin: float = 5.0
    _token: Optional[str] = None
    _expires_at: float = 0.0

    def get_token(self) -> str:
        now = time.time()
        if self._token and now < self._expires_at - self.refresh_margin:
            return self._token

        deadline = max(int(self.ttl_seconds), 1)
        token, error = self.signer.create_auth_token_with_expiry(deadline)
        if error is not None or token is None:
            raise RuntimeError(f"failed to create auth token: {error}")

        self._token = token
        self._expires_at = now + self.ttl_seconds
        return token


@dataclass
class RestContext:
    api_client: ApiClient
    root_api: RootApi
    account_api: AccountApi
    order_api: OrderApi
    signer: Optional[SignerClient]
    auth_cache: Optional[AuthTokenCache]
    account_index: Optional[int]
    market_ids: List[int]
    authorization_value: Optional[str]
    supports_active_orders: bool
    _logged_missing_active_orders: bool = False

    async def close(self) -> None:
        await self.api_client.close()
        if self.signer is not None:
            await self.signer.close()


def build_rest_context(host: str) -> RestContext:
    logger = logging.getLogger("config.rest")
    configuration = Configuration(host=host)
    api_client = ApiClient(configuration=configuration)
    root_api = RootApi(api_client=api_client)
    account_api = AccountApi(api_client=api_client)
    order_api = OrderApi(api_client=api_client)
    supports_active_orders = hasattr(order_api, "account_active_orders")

    account_index = _parse_optional_int("LIGHTER_ACCOUNT_INDEX")
    if account_index is None:
        logger.info("LIGHTER_ACCOUNT_INDEX not set; account-specific REST polling disabled")

    market_ids = _parse_int_csv("LIGHTER_REST_MARKET_IDS")
    if market_ids and account_index is None:
        logger.warning("LIGHTER_REST_MARKET_IDS provided but no LIGHTER_ACCOUNT_INDEX; ignoring market IDs")
        market_ids = []

    authorization_value = os.getenv("LIGHTER_API_KEY")
    if authorization_value:
        logger.info("Authorization header value configured for REST requests")

    signer: Optional[SignerClient] = None
    auth_cache: Optional[AuthTokenCache] = None
    private_key = os.getenv("LIGHTER_API_KEY_PRIVATE_KEY")
    api_key_index = _parse_optional_int("LIGHTER_API_KEY_INDEX") or 0
    if private_key and account_index is not None:
        try:
            signer = SignerClient(
                url=host,
                private_key=private_key,
                account_index=account_index,
                api_key_index=api_key_index,
            )
            ttl = _parse_positive_float("LIGHTER_AUTH_TOKEN_TTL_SECONDS", 600.0)
            auth_cache = AuthTokenCache(signer=signer, ttl_seconds=ttl)
            logger.info("Signer client initialised for authenticated REST calls")
        except Exception:
            logger.exception("Failed to initialise SignerClient; authenticated REST endpoints disabled")
            signer = None
            auth_cache = None
    elif market_ids:
        logger.warning(
            "Market IDs configured but API key credentials missing; skipping authenticated REST polling",
        )

    return RestContext(
        api_client=api_client,
        root_api=root_api,
        account_api=account_api,
        order_api=order_api,
        signer=signer,
        auth_cache=auth_cache,
        account_index=account_index,
        market_ids=market_ids,
        authorization_value=authorization_value,
        supports_active_orders=supports_active_orders,
    )


def configure_logging() -> None:
    log_level = os.getenv("LIGHTER_LOG_LEVEL", "INFO").upper()
    logging.basicConfig(
        level=getattr(logging, log_level, logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        stream=sys.stdout,
    )
    logging.getLogger("websockets.client").setLevel(logging.INFO)
    logging.getLogger("urllib3").setLevel(logging.INFO)


async def _poll_account_endpoints(ctx: RestContext, logger: logging.Logger) -> None:
    if ctx.account_index is None:
        return

    try:
        await ctx.account_api.account(by="index", value=str(ctx.account_index))
        logger.debug("Fetched account %s", ctx.account_index)
    except Exception:
        logger.exception("Failed to fetch account detail for %s", ctx.account_index)

    if not ctx.market_ids or ctx.auth_cache is None:
        return

    if not ctx.supports_active_orders:
        if not ctx._logged_missing_active_orders:
            logger.warning(
                "OrderApi has no account_active_orders method; skipping active-order polling",
            )
            ctx._logged_missing_active_orders = True
        ctx.market_ids = []
        return

    try:
        auth_token = ctx.auth_cache.get_token()
    except Exception:
        logger.exception("Failed to generate auth token for REST request")
        return

    for market_id in ctx.market_ids:
        try:
            orders = await ctx.order_api.account_active_orders(
                account_index=ctx.account_index,
                market_id=market_id,
                authorization=ctx.authorization_value,
                auth=auth_token,
            )
            orders_list = getattr(orders, "orders", None)
            if isinstance(orders_list, list):
                order_count = len(orders_list)
            else:
                order_count = "unknown"
            logger.debug(
                "Fetched %s active orders for market %s", order_count, market_id,
            )
        except Exception:
            logger.exception(
                "Failed to fetch active orders for account %s market %s",
                ctx.account_index,
                market_id,
            )


async def rest_poll_loop(
    ctx: RestContext,
    state: HealthState,
    stop_event: asyncio.Event,
    interval: float,
) -> None:
    logger = logging.getLogger("rest_poll")
    logger.info("Starting REST poll loop with %.1f second interval", interval)

    while not stop_event.is_set():
        try:
            await ctx.root_api.info()
            await _poll_account_endpoints(ctx, logger)
            state.mark_rest()
            logger.debug("REST poll succeeded")
        except Exception:  # noqa: BLE001
            logger.exception("REST poll failed")

        try:
            await asyncio.wait_for(stop_event.wait(), timeout=interval)
        except asyncio.TimeoutError:
            continue


async def ws_loop(
    ws_factory: Callable[[], WsClient],
    state: HealthState,
    stop_event: asyncio.Event,
    reconnect_delay: float,
) -> None:
    logger = logging.getLogger("ws_loop")
    logger.info("Starting WebSocket loop")

    while not stop_event.is_set():
        client = ws_factory()
        try:
            await client.run_async()
        except Exception as exc:  # noqa: BLE001
            if stop_event.is_set():
                break
            message = str(exc)
            if "Unhandled message" in message and "'ping'" in message:
                logger.debug("Ignoring server ping frame reported as exception by SDK")
            else:
                logger.exception("WebSocket stream interrupted; retrying in %.1f seconds", reconnect_delay)
        else:
            logger.warning("WebSocket stream ended unexpectedly; retrying in %.1f seconds", reconnect_delay)

        try:
            await asyncio.wait_for(stop_event.wait(), timeout=reconnect_delay)
        except asyncio.TimeoutError:
            continue


def build_ws_factory(
    host: str,
    path: str,
    order_book_ids: Iterable[str],
    account_ids: Iterable[str],
    state: HealthState,
) -> Callable[[], WsClient]:
    order_books = list(order_book_ids)
    accounts = list(account_ids)

    if not order_books and not accounts:
        raise ValueError(
            "At least one of LIGHTER_WS_ORDER_BOOK_IDS or LIGHTER_WS_ACCOUNT_IDS must be set",
        )

    pretty_ws = os.getenv("LIGHTER_WS_LOG_PRETTY", "false").lower() in {"1", "true", "yes"}
    ws_logger = logging.getLogger("ws.listener")

    def on_order_book_update(market_id: str, payload: object) -> None:  # noqa: ANN001
        state.mark_ws(f"order_book:{market_id}")
        if pretty_ws:
            try:
                ws_logger.debug(
                    "order_book/%s update:\n%s",
                    market_id,
                    json.dumps(payload, indent=2, sort_keys=True),
                )
            except (TypeError, ValueError):
                ws_logger.debug("order_book/%s update: %s", market_id, payload)

    def on_account_update(account_id: str, payload: object) -> None:  # noqa: ANN001
        state.mark_ws(f"account:{account_id}")
        if pretty_ws:
            try:
                ws_logger.debug(
                    "account_all/%s update:\n%s",
                    account_id,
                    json.dumps(payload, indent=2, sort_keys=True),
                )
            except (TypeError, ValueError):
                ws_logger.debug("account_all/%s update: %s", account_id, payload)

    def factory() -> WsClient:
        return WsClient(
            host=host,
            path=path,
            order_book_ids=order_books,
            account_ids=accounts,
            on_order_book_update=on_order_book_update,
            on_account_update=on_account_update,
        )

    return factory


def derive_ws_host(rest_host: str, override_ws_host: Optional[str]) -> str:
    if override_ws_host:
        return override_ws_host
    return rest_host.replace("https://", "").replace("http://", "")


async def run() -> None:
    configure_logging()

    rest_host = _resolve_host("LIGHTER_API_HOST", "https://mainnet.zklighter.elliot.ai")
    ws_host_override = os.getenv("LIGHTER_WS_HOST")
    ws_path = os.getenv("LIGHTER_WS_PATH", "/stream")

    order_book_ids = _parse_csv("LIGHTER_WS_ORDER_BOOK_IDS")
    account_ids = _parse_csv("LIGHTER_WS_ACCOUNT_IDS")

    state = HealthState(DEFAULT_STATE_FILE)

    rest_context = build_rest_context(rest_host)
    ws_factory = build_ws_factory(
        host=derive_ws_host(rest_host, ws_host_override),
        path=ws_path,
        order_book_ids=order_book_ids,
        account_ids=account_ids,
        state=state,
    )

    stop_event = asyncio.Event()

    loop = asyncio.get_running_loop()

    def _handle_signal(sig: signal.Signals) -> None:
        logging.getLogger("signal").info("Received %s; shutting down", sig.name)
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, _handle_signal, sig)
        except NotImplementedError:
            signal.signal(sig, lambda _s, _f: stop_event.set())

    rest_task = asyncio.create_task(rest_poll_loop(rest_context, state, stop_event, REST_INTERVAL_SECONDS))
    ws_task = asyncio.create_task(ws_loop(ws_factory, state, stop_event, WS_RECONNECT_DELAY_SECONDS))
    # Optional roundtrip smoke test (guarded by LIGHTER_EXECUTE_ROUNDTRIP_TRADE)
    roundtrip_task = asyncio.create_task(_roundtrip_maybe_run())

    await stop_event.wait()

    tasks = [rest_task, ws_task, roundtrip_task]

    for task in tasks:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)

    await rest_context.close()

    logging.getLogger("main").info("Shutdown complete")


def main() -> None:
    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
