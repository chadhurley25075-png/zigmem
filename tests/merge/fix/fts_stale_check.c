/* fresh read-only connection, zigmem pragmas, PRAGMA quick_check(5) → prints the joined rows (vendored SQLite). */
#include "sqlite3.h"
#include <stdio.h>
int main(int c, char **v) { sqlite3 *d; if (c < 2 || sqlite3_open_v2(v[1], &d, SQLITE_OPEN_READONLY, 0)) return 3;
  sqlite3_exec(d, "PRAGMA mmap_size=134217728; PRAGMA query_only=ON;", 0, 0, 0); sqlite3_stmt *s; int w = 0;
  if (sqlite3_prepare_v2(d, "PRAGMA quick_check(5)", -1, &s, 0)) { printf("prepare: %s\n", sqlite3_errmsg(d)); return 1; }
  while (sqlite3_step(s) == SQLITE_ROW) { printf("%s%s", w++ ? "; " : "", sqlite3_column_text(s, 0)); } printf("\n");
  sqlite3_finalize(s); sqlite3_close(d); return 0; }
