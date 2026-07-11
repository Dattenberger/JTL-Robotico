#!/bin/bash
# Entrypoint for the E2E MSSQL container: fix volume permissions, then drop to
# the non-root mssql user.
#
# SQL Server 2022 runs as the unprivileged user 'mssql' (UID 10001). Docker
# named volumes are created root-owned, so ownership must be fixed before
# sqlservr starts as mssql. Requires `user: root` in docker-compose.yml.

set -e

chown -R mssql:root /var/opt/mssql

# su (not gosu/setpriv — not guaranteed present in the MSSQL image).
exec su mssql -s /bin/bash -c '/opt/mssql/bin/sqlservr'
