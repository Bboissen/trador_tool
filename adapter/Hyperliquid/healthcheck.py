import os
import requests

from hyperliquid.info import Info

from runtime_config import ensure_sdk_config, resolve_api_base_url


def _build_info():
    api_url = resolve_api_base_url()
    ensure_sdk_config()
    return Info(api_url, skip_ws=True)

def check_sdk_reachability():
    try:
        info = _build_info()
        meta = info.meta()
        exchange_timestamp = meta.get("time") or meta.get("timestamp") or meta.get("serverTime")
        if exchange_timestamp:
            print(f"SDK Reachability Check: Hyperliquid Timestamp: {exchange_timestamp}")
        else:
            print("SDK Reachability Check: Meta retrieved.")
        return True
    except Exception as e:
        print(f"SDK Reachability Check Failed: {e}")
        return False

def check_venue_availability():
    try:
        base_url = resolve_api_base_url()
        response = requests.get(f"{base_url}/info", timeout=5)
        response.raise_for_status()
        print(f"Venue Availability Check: Status Code {response.status_code}")
        return True
    except requests.exceptions.RequestException as e:
        print(f"Venue Availability Check Failed: {e}")
        return False

def send_heartbeat():
    heartbeat_url = os.getenv("HEARTBEAT_URL")
    if heartbeat_url:
        try:
            requests.post(heartbeat_url, json={"status": "healthy"}, timeout=5)
            print("Outbound Heartbeat Sent.")
            return True
        except requests.exceptions.RequestException as e:
            print(f"Outbound Heartbeat Failed: {e}")
            return False
    print("HEARTBEAT_URL not set, skipping outbound heartbeat.")
    return True

if __name__ == "__main__":
    sdk_healthy = check_sdk_reachability()
    venue_healthy = check_venue_availability()
    heartbeat_sent = send_heartbeat()

    if sdk_healthy and venue_healthy and heartbeat_sent:
        print("Health check passed.")
        exit(0)
    else:
        print("Health check failed.")
        exit(1)
