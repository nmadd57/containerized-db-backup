#!/bin/bash
set -euo pipefail

INTERVAL="${BACKUP_INTERVAL_SECONDS:-86400}"
RETAIN_DAYS="${BACKUP_RETAIN_DAYS:-7}"
DEST=/backups

mkdir -p "$DEST/maas" "$DEST/cloudstack"

log() { echo "[$(date -Iseconds)] $*"; }

backup_postgres() {
    local ts="$1"
    local out="$DEST/maas/${ts}.sql.gz"
    local tmp="${out}.tmp"
    log "Backing up MAAS PostgreSQL (${PG_DB})..."
    if ! PGPASSWORD="$PG_PASSWORD" pg_dump \
        -h "$PG_HOST" -p "${PG_PORT:-5432}" \
        -U "$PG_USER" "$PG_DB" \
        | gzip > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$out"
    log "Saved: $out ($(du -sh "$out" | cut -f1))"
}

backup_mariadb() {
    local ts="$1"
    log "Backing up CloudStack MariaDB..."
    # Discover all cloud* databases dynamically
    local dbs
    dbs=$(MYSQL_PWD="$MYSQL_PASSWORD" mysql \
        -h "$MYSQL_HOST" -P "${MYSQL_PORT:-3306}" \
        -u "$MYSQL_USER" -N \
        -e "SHOW DATABASES LIKE 'cloud%';" 2>/dev/null)
    if [ -z "$dbs" ]; then
        log "No cloud* databases found, skipping MariaDB backup."
        return
    fi

    local out="$DEST/cloudstack/${ts}.sql.gz"
    local tmp="${out}.tmp"
    # shellcheck disable=SC2086
    if ! MYSQL_PWD="$MYSQL_PASSWORD" mysqldump \
        -h "$MYSQL_HOST" -P "${MYSQL_PORT:-3306}" \
        -u "$MYSQL_USER" \
        --single-transaction --routines --triggers --events \
        --databases $dbs \
        | gzip > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$out"
    log "Saved: $out ($(du -sh "$out" | cut -f1))"
}

prune() {
    log "Pruning backups older than ${RETAIN_DAYS} days..."
    find "$DEST/maas" "$DEST/cloudstack" -name "*.sql.gz" -mtime +"$RETAIN_DAYS" -delete
    # Clears out partial archives from a run that was killed mid-dump, since
    # those don't match the *.sql.gz glob above and would otherwise pile up.
    find "$DEST/maas" "$DEST/cloudstack" -name "*.sql.gz.tmp" -delete
}

run_backup() {
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    log "--- Starting backup run ---"
    backup_postgres "$ts" || log "ERROR: PostgreSQL backup failed"
    backup_mariadb  "$ts" || log "ERROR: MariaDB backup failed"
    prune
    log "--- Backup run complete ---"
}

run_backup

while true; do
    sleep "$INTERVAL"
    run_backup
done
