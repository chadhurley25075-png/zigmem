/* Merge-lane repro: does a LONG-LIVED read-only connection's PRAGMA quick_check report FTS5 corruption after the writer
 * rewrites FTS5 segments, while a FRESH read-only connection says ok? Vendored SQLite, zigmem's pragmas + l0/l0_fts schema,
 * synthetic rows only.  usage: fts_stale DB PRELOAD CYCLES ROWS_PER_CYCLE MODE   (MODE: none|merge|optimize)            */
#include "sqlite3.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char *PRAG = "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;"
  " PRAGMA cache_size=-65536; PRAGMA mmap_size=134217728; PRAGMA temp_store=MEMORY;";
static void ex(sqlite3 *d, const char *s) { char *e = 0; if (sqlite3_exec(d, s, 0, 0, &e)) { fprintf(stderr, "exec %s: %s\n", s, e); exit(2); } }
static sqlite3 *ro(const char *p) { sqlite3 *d; if (sqlite3_open_v2(p, &d, SQLITE_OPEN_READONLY, 0)) exit(3); ex(d, PRAG); ex(d, "PRAGMA query_only=ON;"); return d; }
static void qc(sqlite3 *d, char *out, int n) { sqlite3_stmt *s; out[0] = 0; if (sqlite3_prepare_v2(d, "PRAGMA quick_check(5)", -1, &s, 0)) { snprintf(out, n, "prepare: %s", sqlite3_errmsg(d)); return; }
  int w = 0, r; while ((r = sqlite3_step(s)) == SQLITE_ROW) w += snprintf(out + w, n - w, "%s%s", w ? "; " : "", (const char *)sqlite3_column_text(s, 0));
  if (r != SQLITE_DONE) snprintf(out + w, n - w, "%sstep: %s", w ? "; " : "", sqlite3_errmsg(d)); sqlite3_finalize(s); }
static const char *W[] = {"kal","vor","min","dus","pel","tor","sab","lin","rue","gat","zen","mor","fip","lod","wex","quo"};
static long id = 0;
static void ins(sqlite3 *d, sqlite3_stmt *st) { char t[256]; int w = snprintf(t, sizeof t, "syn row %ld", id);
  for (int i = 0; i < 14; i++) w += snprintf(t + w, sizeof t - w, " %s%d", W[rand() % 16], rand() % 500);
  char sh[32]; snprintf(sh, sizeof sh, "%031ld", id);
  sqlite3_bind_text(st, 1, t, -1, SQLITE_TRANSIENT); sqlite3_bind_blob(st, 2, sh, 31, SQLITE_TRANSIENT);
  if (sqlite3_step(st) != SQLITE_DONE) { fprintf(stderr, "insert: %s\n", sqlite3_errmsg(d)); exit(4); } sqlite3_reset(st); id++; }
int main(int c, char **v) {
  if (c < 6) return 1; const char *p = v[1]; long pre = atol(v[2]); int cyc = atoi(v[3]); int per = atoi(v[4]); const char *mode = v[5];
  srand(7); sqlite3 *wr; if (sqlite3_open(p, &wr)) return 3; ex(wr, PRAG);
  ex(wr, "CREATE TABLE IF NOT EXISTS l0(id INTEGER PRIMARY KEY, text TEXT NOT NULL, sha256 BLOB NOT NULL UNIQUE);"
         "CREATE VIRTUAL TABLE IF NOT EXISTS l0_fts USING fts5(text, content='l0', content_rowid='id', tokenize='porter unicode61 remove_diacritics 2');"
         "CREATE TRIGGER IF NOT EXISTS l0_fts_ai AFTER INSERT ON l0 BEGIN INSERT INTO l0_fts(rowid, text) VALUES (new.id, new.text); END;");
  sqlite3_stmt *st; sqlite3_prepare_v2(wr, "INSERT INTO l0(id,text,sha256) VALUES(NULL,?1,?2)", -1, &st, 0);
  ex(wr, "BEGIN"); for (long i = 0; i < pre; i++) { ins(wr, st); if (i % 5000 == 4999) { ex(wr, "COMMIT"); ex(wr, "BEGIN"); } } ex(wr, "COMMIT");
  sqlite3 *A = ro(p); char ra[600], rb[600]; int afail = 0, bfail = 0, reopen = 0;
  qc(A, ra, sizeof ra); printf("start long-lived A: %s (sqlite %s)\n", ra, sqlite3_libversion());
  for (int k = 0; k < cyc; k++) {
    for (int i = 0; i < per; i++) ins(wr, st);                       /* one commit per row, as /v1/capture */
    if (!strcmp(mode, "merge")) ex(wr, "INSERT INTO l0_fts(l0_fts, rank) VALUES('merge', 64)");
    else if (!strcmp(mode, "optimize")) ex(wr, "INSERT INTO l0_fts(l0_fts) VALUES('optimize')");
    qc(A, ra, sizeof ra);
    sqlite3 *B = ro(p); qc(B, rb, sizeof rb); sqlite3_close(B);
    int aok = !strcmp(ra, "ok"), bok = !strcmp(rb, "ok"); afail += !aok; bfail += !bok;
    printf("cycle %d rows %ld  A(long-lived)=%s  B(fresh)=%s\n", k, id, aok ? "ok" : ra, bok ? "ok" : rb); fflush(stdout);
    if (!aok) { sqlite3_close(A); A = ro(p); reopen++; }               /* the hub's policy: reopen only after a failure */
  }
  printf("SUMMARY mode=%s cycles=%d A_fail=%d B_fail=%d A_reopens=%d rows=%ld\n", mode, cyc, afail, bfail, reopen, id);
  sqlite3_close(A); sqlite3_finalize(st); sqlite3_close(wr); return 0; }
