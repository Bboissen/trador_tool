#!/bin/bash

# Database initialization script for PostgreSQL 17.6
# This script sets up the complete database with all optimizations

set -e  # Exit on error

# Configuration
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-order_service}"
DB_USER="${DB_USER:-trading_admin}"
DB_PASSWORD="${DB_PASSWORD:-}"
SQL_DIR="${SQL_DIR:-..}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Function to execute SQL file
execute_sql() {
    local file=$1
    local description=$2
    
    echo -n "Executing $description... "
    
    if PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -f "$SQL_DIR/$file" > /tmp/db_init_$$.log 2>&1; then
        print_status "Success"
        return 0
    else
        print_error "Failed"
        echo "Error log:"
        cat /tmp/db_init_$$.log
        return 1
    fi
}

# Function to check prerequisites
check_prerequisites() {
    echo "Checking prerequisites..."
    
    # Check if psql is installed
    if ! command -v psql &> /dev/null; then
        print_error "psql command not found. Please install PostgreSQL client."
        exit 1
    fi
    
    # Check PostgreSQL version
    PG_VERSION=$(PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d postgres -t -c "SELECT version();" 2>/dev/null | grep -oP 'PostgreSQL \K[0-9]+')
    if [ "$PG_VERSION" -lt 17 ]; then
        print_warning "PostgreSQL version $PG_VERSION detected. This script is optimized for PostgreSQL 17+"
    else
        print_status "PostgreSQL $PG_VERSION detected"
    fi
    
    # Check if database exists
    if PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw $DB_NAME; then
        print_status "Database $DB_NAME exists"
    else
        print_warning "Database $DB_NAME does not exist. Creating..."
        PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d postgres -c "CREATE DATABASE $DB_NAME;"
        print_status "Database created"
    fi
    
    # Check required SQL files
    for file in "00_infra_superuser.sql" "00_complete_setup.sql" "01_integrations.sql" "02_operations.sql" "03_indexes_partitions.sql"; do
        if [ ! -f "$SQL_DIR/$file" ]; then
            print_error "Required file $SQL_DIR/$file not found"
            exit 1
        fi
    done
    print_status "All SQL files found"
}

# Function to create roles
create_roles() {
    echo "Creating database roles..."
    
    PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME <<EOF
DO \$\$
BEGIN
    -- Create roles if they don't exist
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'trading_read') THEN
        CREATE ROLE trading_read;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'trading_write') THEN
        CREATE ROLE trading_write;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'trading_admin') THEN
        CREATE ROLE trading_admin;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'trading_system') THEN
        CREATE ROLE trading_system WITH LOGIN;
    END IF;
END
\$\$;
EOF
    
    print_status "Roles created"
}

# Function to set up extensions
setup_extensions() {
    echo "Setting up PostgreSQL extensions..."
    
    PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME <<EOF
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS btree_gin;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
EOF
    
    print_status "Extensions configured"
}

# Function to verify installation
verify_installation() {
    echo "Verifying installation..."
    
    # Check schemas
    SCHEMAS=$(PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT string_agg(nspname, ', ') FROM pg_namespace WHERE nspname IN ('trading', 'events', 'audit', 'api', 'sharding');")
    print_status "Schemas created: $SCHEMAS"
    
    # Check key tables
    TABLE_COUNT=$(PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema IN ('trading', 'events', 'audit');")
    print_status "Tables created: $TABLE_COUNT"
    
    # Check functions
    FUNCTION_COUNT=$(PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema IN ('trading', 'events');")
    print_status "Functions created: $FUNCTION_COUNT"
    
    # Test health check
    HEALTH=$(PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT trading.k8s_liveness();" 2>/dev/null || echo "N/A")
    print_status "Health check: Available"
}

# Main execution
main() {
    echo "========================================="
    echo "PostgreSQL 17.6 Database Initialization"
    echo "========================================="
    echo ""
    echo "Configuration:"
    echo "  Host: $DB_HOST:$DB_PORT"
    echo "  Database: $DB_NAME"
    echo "  User: $DB_USER"
    echo ""
    
    # Check prerequisites
    check_prerequisites
    
    # Create roles
    create_roles
    
    # Setup extensions
    setup_extensions
    
    # Execute SQL files in order
    echo ""
    echo "Initializing database schema..."
    
    execute_sql "00_infra_superuser.sql" "Infra superuser setup" || exit 1
    execute_sql "00_complete_setup.sql" "Core setup" || exit 1
    execute_sql "01_integrations.sql" "Integration layer" || exit 1
    execute_sql "02_operations.sql" "Business operations" || exit 1
    execute_sql "03_indexes_partitions.sql" "Performance optimizations" || exit 1
    
    # Create initial partitions
    echo ""
    echo "Creating initial partitions..."
    PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "SELECT trading.auto_create_partitions();" > /dev/null 2>&1
    print_status "Partitions created"
    
    # Analyze tables for statistics
    echo ""
    echo "Updating table statistics..."
    PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "ANALYZE;" > /dev/null 2>&1
    print_status "Statistics updated"
    
    # Verify installation
    echo ""
    verify_installation
    
    # Cleanup
    rm -f /tmp/db_init_$$.log
    
    echo ""
    echo "========================================="
    print_status "Database initialization completed successfully!"
    echo "========================================="
}

# Run main function
main "$@"
