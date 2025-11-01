#!/bin/sh

# This script performs a basic health check on the Bitget SDK.
# It attempts to fetch the server time using the SDK.

# Assuming the bitget-adapter binary can execute a command to get server time or similar basic info.
# You might need to adjust this command based on the actual SDK's functionality.
# For now, we'll just check if the adapter binary can be executed.

/app/bitget-adapter --healthcheck || exit 1

# If the above command succeeds, the SDK is considered reachable.
exit 0
