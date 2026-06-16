#!/bin/bash
set -euo pipefail

INTERVAL="${BACKUP_INTERVAL_SECONDS:-86400}"
RETAIN_DAYS="${BACKUP_RETAIN_DAYS:-7}"
DEST=/backups

mkdir -p "$DEST/maas" "$DEST/cloudstack" "$DEST/outline"

log() { echo "[$(date -Iseconds)] $*"; }

backup_postgres() {
    local ts="$1" name="$2" host="$3" port="$4" user="$5" pass="$6" db="$7"
    local out="$DEST/$name/${ts}.sql.gz.age"
    local tmp="${out}.tmp"
    log "Backing up $name PostgreSQL (${db})..."
    if ! PGPASSWORD="$pass" pg_dump \
        -h "$host" -p "$port" \
        -U "$user" "$db" \
        | gzip \
        | age -r "$AGE_RECIPIENT" -o "$tmp"; then
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

    local out="$DEST/cloudstack/${ts}.sql.gz.age"
    local tmp="${out}.tmp"
    # shellcheck disable=SC2086
    if ! MYSQL_PWD="$MYSQL_PASSWORD" mysqldump \
        -h "$MYSQL_HOST" -P "${MYSQL_PORT:-3306}" \
        -u "$MYSQL_USER" \
        --single-transaction --routines --triggers --events \
        --databases $dbs \
        | gzip \
        | age -r "$AGE_RECIPIENT" -o "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$out"
    log "Saved: $out ($(du -sh "$out" | cut -f1))"
}

backup_outline_files() {
    local ts="$1"
    local out="$DEST/outline/files_${ts}.tar.gz.age"
    local tmp="${out}.tmp"
    log "Backing up Outline file storage..."
    if ! tar -C /data/outline-files -czf - . \
        | age -r "$AGE_RECIPIENT" -o "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$out"
    log "Saved: $out ($(du -sh "$out" | cut -f1))"
}

upload_remote() {
    log "Uploading backups to $RCLONE_REMOTE..."
    rclone copy "$DEST" "$RCLONE_REMOTE" --include "*.age" -v
    rclone delete "$RCLONE_REMOTE" --min-age "${RETAIN_DAYS}d" --include "*.age" -v
    log "Upload complete."
}

prune() {
    log "Pruning backups older than ${RETAIN_DAYS} days..."
    find "$DEST/maas" "$DEST/cloudstack" "$DEST/outline" -name "*.age" -mtime +"$RETAIN_DAYS" -delete
    # Clears out partial archives from a run that was killed mid-dump, since
    # those don't match the *.age glob above and would otherwise pile up.
    find "$DEST/maas" "$DEST/cloudstack" "$DEST/outline" -name "*.age.tmp" -delete
}

run_backup() {
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    log "--- Starting backup run ---"
    backup_postgres "$ts" maas "$PG_HOST" "${PG_PORT:-5432}" "$PG_USER" "$PG_PASSWORD" "$PG_DB" || log "ERROR: MAAS PostgreSQL backup failed"
    backup_mariadb "$ts" || log "ERROR: MariaDB backup failed"
    backup_postgres "$ts" outline "$OUTLINE_PG_HOST" "${OUTLINE_PG_PORT:-5432}" "$OUTLINE_PG_USER" "$OUTLINE_PG_PASSWORD" "$OUTLINE_PG_DB" || log "ERROR: Outline PostgreSQL backup failed"
    backup_outline_files "$ts" || log "ERROR: Outline file storage backup failed"
    prune
    upload_remote || log "ERROR: Remote upload failed"
    log "--- Backup run complete ---"
}

run_backup

while true; do
    sleep "$INTERVAL"
    run_backup
done
