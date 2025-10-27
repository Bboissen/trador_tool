-- 00_infra_superuser.sql
-- Run by a superuser before application migrations
-- Enables extensions and creates roles

-- ============================================================================
-- SCHEMAS
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS trading;
CREATE SCHEMA IF NOT EXISTS events;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS api;
CREATE SCHEMA IF NOT EXISTS sharding;

-- ============================================================================
-- EXTENSIONS
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS bloom;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ============================================================================
-- ROLES
-- ============================================================================
DO $$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'trading_admin') THEN
      CREATE ROLE trading_admin;
   END IF;
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'trading_system') THEN
      CREATE ROLE trading_system;
   END IF;
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'trading_app') THEN
      CREATE ROLE trading_app;
   END IF;
END
$$;

-- ============================================================================
-- GRANTS
-- ============================================================================
GRANT ALL ON SCHEMA trading, events, audit, api, sharding TO trading_admin;
GRANT USAGE ON SCHEMA trading, events, audit, api, sharding TO trading_system, trading_app;

-- Grant permissions for application roles
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA trading, events, audit, api, sharding TO trading_system;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA trading, events, audit, api, sharding TO trading_app;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA trading, events, audit, api, sharding TO trading_system, trading_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA trading, events, audit, api, sharding TO trading_system, trading_app;

