#!/bin/bash
set -euo pipefail

INTERVAL="${BACKUP_INTERVAL_SECONDS:-86400}"
RETAIN_DAYS="${BACKUP_RETAIN_DAYS:-7}"
DEST=/backups

mkdir -p "$DEST/maas" "$DEST/cloudstack" "$DEST/outline" "$DEST/pocketid" "$DEST/pyramid"

log() { echo "[$(date -Iseconds)] $*"; }

validate_config() {
    local ok=1

    # RETAIN_DAYS must be a positive integer to prevent injection into
    # `find -mtime` and `rclone delete --min-age`.
    if ! [[ "$RETAIN_DAYS" =~ ^[1-9][0-9]*$ ]]; then
        log "ERROR: BACKUP_RETAIN_DAYS must be a positive integer (got: '$RETAIN_DAYS')"
        ok=0
    fi

    # AGE_RECIPIENT must look like an age X25519 public key (age1<bech32>).
    # This catches missing/wrong key before any backup runs — a bad recipient
    # causes age to fail silently on some builds, which would produce output
    # that cannot be decrypted.
    if ! [[ "$AGE_RECIPIENT" =~ ^age1[a-z0-9]{10,}$ ]]; then
        log "ERROR: AGE_RECIPIENT does not look like an age public key (expected age1..., got: '${AGE_RECIPIENT:0:8}...')"
        ok=0
    fi

    [ "$ok" -eq 1 ]
}

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

backup_pocketid() {
    local ts="$1"
    local snap="/tmp/pocketid-snap.db"
    local db_out="$DEST/pocketid/${ts}.db.gz.age"
    local db_tmp="${db_out}.tmp"
    local uploads_out="$DEST/pocketid/uploads_${ts}.tar.gz.age"
    local uploads_tmp="${uploads_out}.tmp"

    log "Backing up PocketID database..."
    sqlite3 /data/pocketid/pocket-id.db "VACUUM INTO '${snap}'"
    if ! gzip -c "$snap" | age -r "$AGE_RECIPIENT" -o "$db_tmp"; then
        rm -f "$db_tmp" "$snap"
        return 1
    fi
    rm -f "$snap"
    mv "$db_tmp" "$db_out"
    log "Saved: $db_out ($(du -sh "$db_out" | cut -f1))"

    log "Backing up PocketID uploads..."
    if ! tar -C /data/pocketid \
        --exclude='./GeoLite2-City.mmdb' \
        --exclude='./*.db' \
        --exclude='./*.db-wal' \
        --exclude='./*.db-shm' \
        -czf - uploads/ \
        | age -r "$AGE_RECIPIENT" -o "$uploads_tmp"; then
        rm -f "$uploads_tmp"
        return 1
    fi
    mv "$uploads_tmp" "$uploads_out"
    log "Saved: $uploads_out ($(du -sh "$uploads_out" | cut -f1))"
}

backup_pyramid() {
    local ts="$1"
    local out="$DEST/pyramid/${ts}.tar.gz.age"
    local tmp="${out}.tmp"
    log "Backing up Pyramid relay data..."
    if ! tar -C /data/pyramid \
        --exclude='./*/lock.mdb' \
        --exclude='./*.lock' \
        --exclude='./log' \
        -czf - . \
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
    find "$DEST/maas" "$DEST/cloudstack" "$DEST/outline" "$DEST/pocketid" "$DEST/pyramid" -name "*.age" -mtime +"$RETAIN_DAYS" -delete
    # Clears out partial archives from a run that was killed mid-dump, since
    # those don't match the *.age glob above and would otherwise pile up.
    find "$DEST/maas" "$DEST/cloudstack" "$DEST/outline" "$DEST/pocketid" "$DEST/pyramid" -name "*.age.tmp" -delete
}

run_backup() {
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    log "--- Starting backup run ---"
    backup_postgres "$ts" maas "$PG_HOST" "${PG_PORT:-5432}" "$PG_USER" "$PG_PASSWORD" "$PG_DB" || log "ERROR: MAAS PostgreSQL backup failed"
    backup_mariadb "$ts" || log "ERROR: MariaDB backup failed"
    backup_postgres "$ts" outline "$OUTLINE_PG_HOST" "${OUTLINE_PG_PORT:-5432}" "$OUTLINE_PG_USER" "$OUTLINE_PG_PASSWORD" "$OUTLINE_PG_DB" || log "ERROR: Outline PostgreSQL backup failed"
    backup_outline_files "$ts" || log "ERROR: Outline file storage backup failed"
    backup_pocketid "$ts" || log "ERROR: PocketID backup failed"
    backup_pyramid "$ts" || log "ERROR: Pyramid backup failed"
    prune
    upload_remote || log "ERROR: Remote upload failed"
    log "--- Backup run complete ---"
}

validate_config || exit 1

run_backup

while true; do
    sleep "$INTERVAL"
    run_backup
done
