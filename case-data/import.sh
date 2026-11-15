#!/bin/sh
# Loads the case data on every `docker compose up` (the case-data service of docker-compose.yaml):
#   1. restores the PostgreSQL dump from ./data (the first *.backup file) into the case_data database of the shared
#      Postgres; it is restored again only when the dump file changes;
#   2. exports the catalog and the interaction log as JSON into the case_export volume (catalog.sql, events.sql),
#      which catalog-service and metric-service import at startup.
# Without a dump, ./data/catalog.json and ./data/events.json are handed over when they exist. If loading fails, the
# lists are empty and the error is logged: the rest of the system must start anyway.
set -eu

DATA_DIR=/data
EXPORT_DIR=/export
SCRIPTS_DIR=/case-data
DATABASE=case_data

log() {
    echo "case-data: $*"
}

restore() {
    checksum=$(sha256sum "$1" | cut -d ' ' -f 1) || return 1
    restored=$(psql -d postgres -tAc \
        "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname = '$DATABASE'") || return 1

    if [ "$restored" = "$checksum" ]; then
        log "$(basename "$1") is already restored"
        return 0
    fi

    log "restoring $(basename "$1") into the $DATABASE database"
    dropdb --if-exists "$DATABASE" || return 1
    createdb "$DATABASE" || return 1
    pg_restore --no-owner --no-privileges --exit-on-error -d "$DATABASE" "$1" || return 1
    # The checksum marks a complete restore; a failed one is retried on the next start
    psql -d postgres -qc "COMMENT ON DATABASE $DATABASE IS '$checksum'" || return 1
}

export_json() {
    for name in catalog events; do
        psql -d "$DATABASE" -v ON_ERROR_STOP=1 -qAt -f "$SCRIPTS_DIR/$name.sql" > "$EXPORT_DIR/$name.json.tmp" || return 1
    done
    for name in catalog events; do
        mv "$EXPORT_DIR/$name.json.tmp" "$EXPORT_DIR/$name.json" || return 1
    done
    log "exported $(grep -o '"id" :' "$EXPORT_DIR/catalog.json" | wc -l) materials" \
        "and $(grep -o '"userId" :' "$EXPORT_DIR/events.json" | wc -l) events"
}

# The JSON files from ./data when they exist, otherwise empty lists.
hand_over_data_files() {
    for name in catalog.json events.json; do
        if [ -f "$DATA_DIR/$name" ]; then
            cp "$DATA_DIR/$name" "$EXPORT_DIR/$name.tmp"
        else
            echo '[]' > "$EXPORT_DIR/$name.tmp"
        fi
        mv "$EXPORT_DIR/$name.tmp" "$EXPORT_DIR/$name"
    done
}

dump=$(find "$DATA_DIR" -maxdepth 1 -type f -name '*.backup' | sort | head -n 1)

if [ -z "$dump" ]; then
    log "no *.backup in ./data: using ./data/catalog.json and ./data/events.json if they exist"
    hand_over_data_files
elif restore "$dump" && export_json; then
    :
else
    log "ERROR: could not load $(basename "$dump"), see the messages above; starting without the case data" >&2
    rm -f "$EXPORT_DIR"/*.tmp
    hand_over_data_files
fi
