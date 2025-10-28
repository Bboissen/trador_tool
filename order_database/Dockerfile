FROM postgres:18

# Copy initialization SQL files. These run once on first init (empty data dir),
# in lexicographical order, against $POSTGRES_DB (set via compose.yml).
COPY 00_extensions.sql \
     01_complete_setup.sql \
     02_integrations.sql \
     03_operations.sql \
     04_indexes_partitions.sql \
     /docker-entrypoint-initdb.d/

# Ensure scripts are readable by the postgres user
RUN chmod 0644 /docker-entrypoint-initdb.d/*.sql

# Note: shared_preload_libraries is configured via docker compose CLI args
# to enable pg_stat_statements when the container starts.
