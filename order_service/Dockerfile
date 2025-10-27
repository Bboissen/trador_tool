FROM postgres:18

# Copy initialization SQL files. These run once on first init (empty data dir),
# in lexicographical order, against $POSTGRES_DB (set in docker-compose).
# Ensure schema creation runs before dependent setup by controlling filenames
COPY 00_infra_superuser.sql /docker-entrypoint-initdb.d/00a_infra_superuser.sql
COPY 00_complete_setup.sql /docker-entrypoint-initdb.d/00b_complete_setup.sql
COPY 01_integrations.sql \
     02_operations.sql \
     03_security_monitoring.sql \
     04_indexes_partitions.sql \
     /docker-entrypoint-initdb.d/

# Ensure scripts are readable by the postgres user
RUN chmod 0644 /docker-entrypoint-initdb.d/*.sql

# Note: shared_preload_libraries is configured via docker-compose command line
# to enable pg_stat_statements when the container starts.
