// Linux only. GRDB references SQLite's WAL snapshot API unconditionally, but the SQLite that
// ships with Ubuntu is built without SQLITE_ENABLE_SNAPSHOT, so linking fails. The app never
// uses snapshots (it uses a plain DatabaseQueue); these stubs only satisfy the linker so the
// platform-independent code can be tested on Linux CI. They are not compiled on macOS.
#ifdef __linux__
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_snapshot sqlite3_snapshot;
int sqlite3_snapshot_get(sqlite3 *db, const char *schema, sqlite3_snapshot **out) { return 1; }
int sqlite3_snapshot_open(sqlite3 *db, const char *schema, sqlite3_snapshot *snapshot) { return 1; }
void sqlite3_snapshot_free(sqlite3_snapshot *snapshot) {}
int sqlite3_snapshot_cmp(sqlite3_snapshot *a, sqlite3_snapshot *b) { return 0; }
#endif
