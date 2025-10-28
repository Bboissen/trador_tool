#!/bin/bash

# Database reset script for development
# WARNING: This will DROP and recreate the database!

set -e  # Exit on error

# Configuration
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-order_service}"
DB_USER="${DB_USER:-trading_admin}"
DB_PASSWORD="${DB_PASSWORD:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

# Confirmation prompt
confirm_reset() {
    echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                         WARNING!                          ║${NC}"
    echo -e "${RED}║                                                           ║${NC}"
    echo -e "${RED}║  This will completely DROP and recreate the database:    ║${NC}"
    echo -e "${RED}║  Database: $DB_NAME                                      ║${NC}"
    echo -e "${RED}║  Host: $DB_HOST:$DB_PORT                                 ║${NC}"
    echo -e "${RED}║                                                           ║${NC}"
    echo -e "${RED}║  ALL DATA WILL BE PERMANENTLY LOST!                      ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    read -p "Are you ABSOLUTELY sure you want to continue? Type 'RESET' to confirm: " confirmation
    
    if [ "$confirmation" != "RESET" ]; then
        print_error "Reset cancelled"
        exit 1
    fi
    
    echo ""
    read -p "This is your last chance. Type the database name '$DB_NAME' to proceed: " db_confirm
    
    if [ "$db_confirm" != "$DB_NAME" ]; then
        print_error "Reset cancelled"
        exit 1
    fi
}

# Terminate active connections
terminate_connections() {
    print_info "Terminating active connections..."
    
    PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d postgres <<EOF
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '$DB_NAME'
  AND pid <> pg_backend_pid();
EOF
    
    print_status "Connections terminated"
}

# Drop database
drop_database() {
    print_info "Dropping database $DB_NAME..."
    
    if PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d postgres -c "DROP DATABASE IF EXISTS $DB_NAME;" 2>/dev/null; then
        print_status "Database dropped"
    else
        print_error "Failed to drop database"
        exit 1
    fi
}

# Create database
create_database() {
    print_info "Creating database $DB_NAME..."
    
    PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d postgres <<EOF
CREATE DATABASE $DB_NAME
    WITH 
    OWNER = $DB_USER
    ENCODING = 'UTF8'
    LC_COLLATE = 'en_US.UTF-8'
    LC_CTYPE = 'en_US.UTF-8'
    TABLESPACE = pg_default
    CONNECTION LIMIT = -1;
    
COMMENT ON DATABASE $DB_NAME IS 'Trading system database - PostgreSQL 17.6';
EOF
    
    print_status "Database created"
}

# Initialize schema
initialize_schema() {
    print_info "Initializing database schema..."
    
    # Run the init script
    if [ -f "./init_db.sh" ]; then
        ./init_db.sh
    else
        print_error "init_db.sh not found in current directory"
        exit 1
    fi
}

# Load sample data (optional)
load_sample_data() {
    print_info "Loading sample data..."
    
    PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME <<'EOF'
-- Insert sample networks
INSERT INTO trading.networks (name, chain_id, chain_type, rpc_endpoints) VALUES
    ('ethereum-mainnet', 1, 'EVM', ARRAY['https://eth.llamarpc.com']),
    ('polygon-mainnet', 137, 'EVM', ARRAY['https://polygon-rpc.com']),
    ('arbitrum-one', 42161, 'EVM', ARRAY['https://arb1.arbitrum.io/rpc']);

-- Insert sample tokens
INSERT INTO trading.tokens (network_id, symbol, name, address, decimals, is_stablecoin) VALUES
    (1, 'USDT', 'Tether USD', '\xdac17f958d2ee523a2206206994597c13d831ec7'::bytea, 6, true),
    (1, 'USDC', 'USD Coin', '\xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48'::bytea, 6, true),
    (1, 'WETH', 'Wrapped Ether', '\xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2'::bytea, 18, false),
    (1, 'DAI', 'Dai Stablecoin', '\x6b175474e89094c44da98b954eedeac495271d0f'::bytea, 18, true);

-- Insert sample wallets
INSERT INTO trading.wallets (daily_limit, monthly_limit, max_orders_per_hour, max_orders_per_day) VALUES
    (1000000000000, 10000000000000, 100, 1000),
    (500000000000, 5000000000000, 50, 500),
    (100000000000, 1000000000000, 20, 200);

-- Insert sample wallet addresses
INSERT INTO trading.wallet_addresses (wallet_id, network_id, address) VALUES
    (1, 1, '\x742d35Cc6634C0532925a3b844Bc9e7595f0bEb3'::bytea),
    (2, 1, '\x5aAeb6053f3E94C9b9A09f33669435E7Ef1BeAed'::bytea),
    (3, 1, '\xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359'::bytea);

-- Insert sample balances
INSERT INTO trading.account_balances (wallet_id, token_id, available, reserved) VALUES
    (1, 1, 1000000000000, 0),  -- 1M USDT
    (1, 2, 1000000000000, 0),  -- 1M USDC
    (1, 3, 1000000000000000000000, 0),  -- 1000 WETH
    (2, 1, 500000000000, 0),   -- 500K USDT
    (2, 2, 500000000000, 0),   -- 500K USDC
    (3, 1, 100000000000, 0);   -- 100K USDT

-- Insert sample health checks
INSERT INTO trading.health_checks (component, status) VALUES
    ('database', 'HEALTHY'),
    ('event_bus', 'HEALTHY'),
    ('matching_engine', 'HEALTHY');

ANALYZE;
EOF
    
    print_status "Sample data loaded"
}

# Main execution
main() {
    echo "========================================="
    echo "Database Reset Script"
    echo "========================================="
    echo ""
    
    # Check if running in production
    if [ "$ENVIRONMENT" = "production" ] || [ "$ENV" = "production" ]; then
        print_error "Cannot run reset in production environment!"
        exit 1
    fi
    
    # Get confirmation
    confirm_reset
    
    echo ""
    print_warning "Starting database reset..."
    echo ""
    
    # Execute reset steps
    terminate_connections
    drop_database
    create_database
    
    echo ""
    initialize_schema
    
    echo ""
    read -p "Load sample data? (y/n): " load_samples
    if [ "$load_samples" = "y" ] || [ "$load_samples" = "Y" ]; then
        load_sample_data
    fi
    
    echo ""
    echo "========================================="
    print_status "Database reset completed successfully!"
    echo "========================================="
    echo ""
    print_info "Database is ready for development"
}

# Run main function
main "$@"
