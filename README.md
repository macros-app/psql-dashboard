# psql-dashboard

A PostgreSQL dashboard for the [macros](https://github.com/kylegwinnup/macros)
editor, written in Steel — a magit-style porcelain for `psql`.

One read-only, foldable dashboard shows the database at a glance: every schema
with its relations (tables, views, matviews), estimated row counts, on-disk
sizes, and live backend activity. `TAB` drills into a schema, then into a table
(columns, indexes, constraints, stats, size breakdown). `s` opens a half-window
**sql-mode** query pane — write SQL with real tree-sitter highlighting, `C-c
C-c` runs it asynchronously, and the results (psql's aligned output plus
`\timing`) land in a results buffer.

The Rust core knows nothing about Postgres — the package sits entirely on the
same editor primitives magit and macros-k8s use: `call-process-full` (catalog
queries), `lib-async` (cancellable async user queries), `lib-section` (foldable
sections), `render-buffer`, `split-window-below` + `set-major-mode` (the query
pane), and `lib-transient` (the `?` popup).

## Requirements

- The [macros](https://github.com/kylegwinnup/macros) editor.
- `psql` on your `PATH` (any reasonably recent PostgreSQL client; the catalog
  queries need server ≥ 9.4).

## Install

Add this to your `init.scm` — the package is cloned from git on first launch:

```scheme
(package-install "https://github.com/macros-app/psql-dashboard"
  'config (lambda () (set-option "psql-url" "postgres://user:pass@localhost:5432/mydb")))
```

Or, while developing, load it in place:

```scheme
(package-install-local "~/workspace/psql-dashboard"
  'config (lambda () (set-option "psql-url" "postgres://user:pass@localhost:5432/mydb")))
```

## Configuration

The connection URL lives in the editor's **option store** (order-independent —
set it any time):

```scheme
(set-option "psql-url" "postgres://user:pass@host:5432/dbname")
```

Anything `psql -d` accepts works (a URL or a key/value conninfo string). If the
option is empty or unset, `psql` falls back to its own defaults — `PGHOST`,
`PGDATABASE`, `PGUSER`, `~/.pgpass`, and friends — so an already-configured
environment needs no option at all. Change it at runtime with `U` in any
dashboard buffer or `M-x psql-set-url`. Passwords are redacted (`user:***@`)
everywhere the URL is displayed.

The psql executable is the `psql-command` option (default `"psql"`). The GUI
editor does **not** inherit your shell PATH, so on a typical macOS install
point it at the binary directly:

```scheme
(set-option "psql-command" "/opt/homebrew/opt/libpq/bin/psql")   ; Homebrew libpq
;; or "/Applications/Postgres.app/Contents/Versions/latest/bin/psql"
```

Faces are user-overridable — redefine after loading (and re-apply after a
`load-theme`, which wipes the palette): `psql-header`, `psql-section`,
`psql-ok`, `psql-warn`, `psql-err`, `psql-dim`.

## Launch

`M-x psql-dashboard` opens the `*psql-dashboard*` buffer.

The package adds **no global keybindings**. Bind it yourself if you want a key
— e.g. in `init.scm`:

```scheme
(define-key "fundamental" "ctrl-c d" 'psql-dashboard)
```

## The dashboard

```
Database: mydb   PostgreSQL 16.3   postgres://kyle:***@localhost:5432/mydb
Size: 7509 kB   User: kyle   Connections: 5 (1 active)

public  (12 relations · 1.2 GB · kyle)
    NAME       TYPE   ~ROWS  SIZE
    events     table  4.1M   890.0 MB
    users      table  1.5k   80.0 KB
    user_view  view   -      -

Activity (1)
    PID  USER  STATE   TIME      QUERY
    123  kyle  active  00:00:01  select …
```

Each schema is a foldable section listing its relations sorted by size —
`TAB` folds/unfolds it, magit-style. `~ROWS` is the planner's estimate
(`reltuples` — `?` until first `ANALYZE`). The **Activity** section shows the
other backends connected to this database (state, running time, current query).

## Drill-down

- `RET` / `g` on a **schema heading** → `*psql-schema:S*` — owner,
  description, and every relation with a size breakdown (total / table /
  indexes).
- `RET` / `g` on a **table row** → `*psql-table:S.T*` — sizes, row estimate,
  scan and vacuum/analyze stats, then foldable **Columns** (type, null,
  default), **Indexes** (size, scans, definition), **Constraints**, and — for
  views and matviews — the **Definition**.
- `^` goes back up a level (table → schema → dashboard).

## Keys

In the dashboard / schema / table buffers (`psql-mode`):

| Key           | Action                                                     |
| ------------- | ---------------------------------------------------------- |
| `r`           | refresh the current buffer                                 |
| `RET` / `g`   | drill into the schema / table at point                     |
| `TAB`         | fold / unfold the section at point                         |
| `^`           | up a level (table → schema → dashboard)                    |
| `s`           | open the SQL query pane                                    |
| `U`           | set the connection URL                                     |
| `Y`           | copy the qualified name at point (fallback: the line)      |
| `?`           | actions popup for the thing at point                       |
| `j` `k` `n` `p` / arrows | move by line (evil/helix motion works too)      |
| `q`           | close the buffer                                           |

In the results / error buffers (`psql-result-mode`): `yy` copies the current
line, `Y` the whole buffer, `q` closes (vim/helix yank can't reach these
special read-only buffers — same constraint as magit).

## The query pane

`s` (or `M-x psql-query`) splits the window in half and opens `*psql-query*` in
**sql-mode** — a normal editable buffer with tree-sitter SQL highlighting and
all your usual keymaps. Then:

| Key         | Action                                                        |
| ----------- | ------------------------------------------------------------- |
| `C-c C-c`   | run the buffer's SQL (asynchronously — the editor never blocks) |
| `C-c C-g`   | cancel the running query (plain `C-g` also works under Emacs bindings — evil intercepts it) |
| `C-c C-k`   | close the query pane                                          |

Results open in `*psql-results*` in the other window, so the query stays
visible: psql's own aligned table output, `(N rows)` footers, and `\timing`
per statement. Errors and notices are interleaved in statement order. The
buffer may hold multiple statements — each runs in order in one session.

These bindings live in the `sql` major-mode keymap, so `C-c C-c` also runs the
contents of **any `.sql` file buffer** against the configured URL — the Emacs
`sql-mode` habit.

### Completion

The query pane (and any `.sql` buffer) completes from the **connected
database's own catalog** via the editor's completion-at-point chain (`M-i`):

- after `FROM` / `JOIN` / `INTO` / `UPDATE` / `TABLE` → table, `schema.table`,
  and schema names
- after `schema.` → that schema's tables
- after `table.` → that table's columns
- anywhere else → SQL keywords (matching your case: `SEL` → `SELECT`, `sel` →
  `select`) plus tables, plus columns once you've typed a character

Candidates are annotated (a table shows its schema, a column its table). The
catalog is one `pg_attribute` query, fetched lazily on first completion and
refreshed by every dashboard render — or force it with
`M-x psql-catalog-refresh`. Changing the URL invalidates it. A failed fetch is
remembered (completion goes quiet rather than hammering a dead connection);
any dashboard refresh retries.

### Results formatting and caps

Queries run with **sentinel record/field separators** (`-P recordsep` /
`-P fieldsep`), so row and cell boundaries are exact — a value containing a
newline or a `|` cannot break its row. Every row lands in the table. Each
result set is formatted as an **org-mode table**, cells clamped to 80 chars
(`…` marks a clamped cell) and embedded newlines shown as `⏎`:

```
| id                                   | use_type | title                 |
|--------------------------------------+----------+-----------------------|
| f0a67ff1-a760-4ae5-a4a0-2a2d4f7032fa | general  | Untitled spreadsheet… |
(5 rows)
Time: 56.981 ms
```

Results open as a **real org-mode buffer** — a temp `results.org` file — so
the tables fontify and behave as genuine org tables and every keymap works as
in any file (re-running a query re-reads it in place). Rows paste straight
into your org documents, and a babel `#+RESULTS:` block holds a *real* org
table (table lines are inserted raw, not `: `-prefixed).

This
is load-bearing, not cosmetic: psql's own aligned format pads every row and
the separator rule to the *widest* cell, so `select *` over a table with fat
columns (embeddings, blobs, large json) explodes a few MB of data into
**gigabytes of padding** — which looks exactly like a hang. Here a 2 MB
embedding costs 81 characters of screen instead.

Two caps guard runaway results, both leaving what already arrived visible and
labeling the buffer `… truncated …`:

```scheme
(set-option "psql-max-rows" "2000")       ; output lines kept (default 2000)
(set-option "psql-max-output" "50000000") ; raw stream backstop, bytes (50 MB)
```

Hitting either cap **kills psql**, which drops the connection and cancels the
query server-side — nothing keeps streaming in the background. Queries run
with `FETCH_COUNT=100` so results stream in batches and the caps cut in
early. There is **no LIMIT injected**; a huge result set is simply truncated
at the row cap. Cancel a long-running query with `C-g`.


## Org-mode source blocks

`psql` (and `sql`) are registered as org-babel languages, so `C-c C-c` /
`org-babel-execute` inside a source block runs it against the configured URL
and writes the aligned, cell-clamped table into the `#+RESULTS:` block:

```org
#+BEGIN_SRC psql
select id, title from memories limit 5;
#+END_SRC
```

Babel execution is synchronous (the result lands in the buffer), so output is
capped at 1 MB raw / `psql-max-rows` lines — keep org blocks to queries, not
dumps. Requires an editor build with the org-babel executor registry
(`org-babel-register-language`); on older builds the registration is skipped
and everything else still works.

## The `?` popup

With point on a table, `?` offers table info / copy / query / refresh; on a
schema heading, schema info / fold / copy; anywhere else, a view menu (refresh,
query, set URL, up).

## Notes / limitations

- Catalog output is parsed as unaligned `psql -A -t` tuples (no JSON parser in
  Steel). Every query keeps its single free-text column **last**, and the
  parser re-joins stray `|` separators into it, so a `|` inside an index or
  default expression can't shift columns. A `|` inside a *schema or table
  name* would still confuse the dashboard — don't do that.
- Row counts are planner estimates (`pg_class.reltuples`), not `count(*)`.
- Dashboard/drill-down catalog queries are synchronous (they're small);
  only the query pane runs async.
- System schemas (`pg_*`, `information_schema`) are hidden.

## License

MIT — see [LICENSE](LICENSE).
