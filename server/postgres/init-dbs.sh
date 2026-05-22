#!/usr/bin/env bash
# Creates all required databases on first PostgreSQL startup
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    CREATE DATABASE synapse ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C' TEMPLATE template0;
    GRANT ALL PRIVILEGES ON DATABASE synapse TO $POSTGRES_USER;

    CREATE DATABASE nextcloud;
    GRANT ALL PRIVILEGES ON DATABASE nextcloud TO $POSTGRES_USER;

    CREATE DATABASE tak;
    GRANT ALL PRIVILEGES ON DATABASE tak TO $POSTGRES_USER;

    CREATE DATABASE lldap;
    GRANT ALL PRIVILEGES ON DATABASE lldap TO $POSTGRES_USER;

    CREATE DATABASE authelia;
    GRANT ALL PRIVILEGES ON DATABASE authelia TO $POSTGRES_USER;
EOSQL

echo "All KOMMS databases created."
