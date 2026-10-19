# psql-dashboard

A PostgreSQL dashboard for the [macros](https://github.com/kylegwinnup/macros)
editor, written in Steel — a magit-style porcelain for `psql`.

One read-only, foldable dashboard shows the database at a glance: connection
and cache health, a list of things worth a look (bloat, dead rows, unused
indexes, blocked or long-running sessions), live activity, and every schema's
relations with size bars. `RET` drills into a schema, then into a table
(sizes, stats, columns with planner statistics, indexes, constraints,
foreign keys in both directions), and `q` goes back. Every view loads in the
background, so a slow or remote server never freezes the editor. `s` opens a
half-window **sql-mode** query pane — write SQL with real tree-sitter
highlighting, `C-c C-c` runs the statement at point asynchronously, the
results open as a grid, and `C-c C-e` / `C-c C-a` show its plan as a foldable
tree with the slow node marked.

The Rust core knows nothing about Postgres — the package sits entirely on the
same editor primitives magit and macros-k8s use: `lib-async` (cancellable
background catalog fetches and user queries), `lib-section` (foldable
sections), `render-buffer`, `split-window-below` + `set-major-mode` (the query
pane), and `lib-transient` (the `?` popup).

![The dashboard: health header, Attention, TPS trend, activity, and schemas with size bars](screenshots/dashboard.png)

| Table view | Query results as a grid |
| --- | --- |
| ![A table's sizes, stats, columns, indexes, constraints and incoming foreign keys](screenshots/table.png) | ![The SQL query pane with its result open as a grid](screenshots/query.png) |

The screenshots use a demo database with made-up data.

## Requirements

- The [macros](https://github.com/kylegwinnup/macros) editor.
- `psql` on your `PATH` (any reasonably recent PostgreSQL client; the catalog
  queries need server ≥ 10).

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

To keep the URL out of `init.scm`, point the option at an `authinfo.gpg` entry:

```scheme
(set-option "psql-url" (secret-get "prod-read-only" ""))
```

The first command that needs the server asks for the authinfo passphrase, then
— if there's no `prod-read-only` entry yet — for the URL itself, and offers to
save it.

The psql executable is the `psql-command` option (default `"psql"`). The GUI
editor does **not** inherit your shell PATH, so on a typical macOS install
point it at the binary directly:

```scheme
(set-option "psql-command" "/opt/homebrew/opt/libpq/bin/psql")   ; Homebrew libpq
;; or "/Applications/Postgres.app/Contents/Versions/latest/bin/psql"
```

Faces are user-overridable — redefine after loading (and re-apply after a
`load-theme`, which wipes the palette): `psql-header`, `psql-section`,
`psql-ok`, `psql-warn`, `psql-err`, `psql-dim`, `psql-bar` (inline bars and
sparklines).

Other options (all strings, like every option):

```scheme
(set-option "psql-dashboard-rows" "15")   ; relations per schema on the dashboard
(set-option "psql-auto-refresh" "10")     ; auto-refresh interval, seconds
(set-option "psql-preview-rows" "200")    ; rows `v` fetches
(set-option "psql-results-view" "grid")   ; or "org" for org-table results
```

## Launch

`M-x psql-dashboard` opens the `*psql-dashboard*` buffer.

The package adds **no global keybindings**. Bind it yourself if you want a key
— e.g. in `init.scm`:

```scheme
(define-key "fundamental" "ctrl-c d" 'psql-dashboard)
```

## The dashboard

```
Database: mydb   PostgreSQL 16.3   postgres://kyle:***@db:5432/mydb
Size: 1003.2 MB   User: kyle   Up: 105d6h   Connections: 11/400 ▎   1 active · 0 idle in xact · 0 waiting on locks
Cache hit: 99.9% ██████████   TPS: ▅▅▅█ 32/s   Deadlocks: 0   Temp: 339.7 MB

Attention (3)
       CHECK          RELATION              DETAIL
    ▲  empty but big  public.stream_events  14 MB on disk with ~0 live rows — bloat (VACUUM FULL)
    ·  unused index   public.memories       idx_memories_embedding · 11 MB · 0 scans
    ·  not analyzed   -                     61 small tables (< 1 MB) never analyzed — their ~ROWS show ?

Trends            (a TPS chart, from the third refresh on)

Activity (1 non-idle)
    PID  USER  STATE   WAIT  TIME  BLOCKED BY  QUERY
    123  kyle  active        12s               select …

public  (143 relations · 989.6 MB · kyle)
    NAME          TYPE   ~ROWS  SIZE
    llm_messages  table  98.1k  257.2 MB  ████████████████
    events        table  198k   209.3 MB  █████████████
    …
    … 128 more — RET opens public
```

- The **header** shows connections against `max_connections`, the cumulative
  cache hit ratio, and TPS. TPS is a rate, so it needs two refreshes; each
  refresh adds a sample (`a` auto-refreshes). It includes the dashboard's own
  queries, about 9 per refresh.
- **Attention** lists things worth a look: blocked sessions, queries running
  over 5 minutes, sessions idle in a transaction over 1 minute, transaction ID
  age, tables with over 20% dead rows, big tables with ~0 live rows (bloat),
  mostly-sequential-scan tables, unused non-unique indexes over 1 MB, and
  never-analyzed tables. `RET` on a row opens its table.
- **Activity** lists non-idle client sessions, longest-running first, with
  wait event and the pids blocking them.
- **Top queries** appears when `pg_stat_statements` is installed.
- Each **schema** shows its largest `psql-dashboard-rows` relations with a size
  bar; the `… N more` line opens the full list. `~ROWS` is the planner's
  estimate (`reltuples`, `?` until the first `ANALYZE`).

All of a view's catalog queries run over one psql connection, **in the
background**: `RET`, `r`, `^` and auto-refresh return immediately, and the view
draws when the data arrives. The first `M-x psql-dashboard` shows a
"Connecting to …" line until then; drilling in leaves you where you are, with
"opening …" in the echo area. `C-g` (or `C-c C-g` under evil) cancels a fetch
in flight. One fetch runs at a time — asking for another while one is out
queues it, newest request wins, so mashing `r` costs one extra round trip. If
you've moved to another buffer by the time a drill-down arrives, its buffer is
filled in without taking focus. Connecting gives up after
`PGCONNECT_TIMEOUT` seconds (10 unless you set it), so an unreachable host
can't hang the dashboard.

## Drill-down

- `RET` / `g` on a **schema heading** → `*psql-schema:S*` — every relation with
  total / table / index sizes, dead-row %, and a size bar.
- `RET` / `g` on a **table row** → `*psql-table:S.T*`:
  - **Size**: heap / TOAST / indexes as bars with their share of the total.
  - **Stats**: live and dead rows, writes (with HOT-update %), seq vs index
    scans, heap and index cache hit, last vacuum / analyze.
  - **Columns**: type, `PK`/`FK`/`UQ`/`IDX` markers, not-null, and the
    planner's statistics (null %, distinct values, average width), with each
    column's comment underneath.
  - **Indexes**: size and scans as bars, with unused indexes flagged.
  - **Constraints**: `RET` on a foreign key opens the table it references.
  - **Referenced by**: incoming foreign keys; `RET` opens the referencing table.
  - For views and matviews, the **Definition**.

  Long definitions wrap under their column. Fold state is per table.
- `v` on a table row (or in a table buffer) previews its first
  `psql-preview-rows` rows as a grid.
- `q` closes the buffer and returns to the one you opened it from, so
  `RET` … `q` works like back navigation, including through foreign keys.
- `^` goes up a level (table → schema → dashboard).

## Keys

In the dashboard / schema / table buffers (`psql-mode`):

| Key           | Action                                                     |
| ------------- | ---------------------------------------------------------- |
| `r`           | refresh the current buffer (in the background)             |
| `C-g` / `C-c C-g` | cancel a refresh in flight                             |
| `a`           | toggle dashboard auto-refresh                              |
| `v`           | preview the table at point as a grid                       |
| `RET` / `g`   | drill into the schema / table at point                     |
| `TAB`         | fold / unfold the section at point                         |
| `^`           | up a level (table → schema → dashboard)                    |
| `s`           | open the SQL query pane                                    |
| `U`           | set the connection URL                                     |
| `Y`           | copy the qualified name at point (fallback: the line)      |
| `?`           | actions popup for the thing at point                       |
| `j` `k` `n` `p` / arrows | move by line (evil/helix motion works too)      |
| `q`           | close the buffer and go back to where `RET` came from      |

In the results / error buffers (`psql-result-mode`): `yy` copies the current
line, `Y` the whole buffer, `q` closes (vim/helix yank can't reach these
special read-only buffers — same constraint as magit).

## The query pane

`s` (or `M-x psql-query`) splits the window in half and opens `*psql-query*` in
**sql-mode** — a normal editable buffer with tree-sitter SQL highlighting and
all your usual keymaps. Then:

| Key         | Action                                                        |
| ----------- | ------------------------------------------------------------- |
| `C-c C-c`   | run the **region**, or else the **statement at point** (asynchronously — the editor never blocks) |
| `C-c C-b`   | run the whole buffer                                          |
| `C-c C-e`   | `EXPLAIN` the region / statement at point (see below)         |
| `C-c C-a`   | `EXPLAIN (ANALYZE, BUFFERS)` it, inside `BEGIN … ROLLBACK`    |
| `C-c C-g`   | cancel the running query (plain `C-g` also works under Emacs bindings — evil intercepts it) |
| `C-c C-k`   | close the query pane                                          |

Results open in the other window, so the query stays visible, as a **grid**
(a CSV in macros' grid mode: sort, filter, resize columns, copy, formulas).
The header row is frozen, cells hold full values, and the echo area shows the
row count and `\timing`. With `C-c C-b` the buffer may hold several
statements; they run in order in one session, and the **last** result set is
shown, with earlier ones written next to it as `psql-result-N.csv`.

### The statement at point

`C-c C-c` splits the buffer into statements the way psql reads it — at `;`,
ignoring semicolons inside comments, quoted strings and identifiers, and
dollar quotes; a backslash meta-command (`\gx`, `\set …`) ends its line's
statement — and runs the one under the cursor:

- point just past a statement's `;` (where it sits right after you type it)
  runs that statement; on a blank line between two, the one below;
- past the last statement (a trailing blank line), the last one;
- an active region (Emacs mark, evil visual, a helix selection wider than one
  character) runs exactly the selected text instead.

The buffer's other `\set` lines are sent along as a prelude, so
`\set n 5` at the top still applies to `select … :n` further down — no
prompt. Only the statement that ran goes into history.

If a statement errors, or nothing returns rows (DDL, `SET`, …), the output
opens as the org results described below instead, so messages are readable.
Set `psql-results-view` to `"org"` to always get org tables.

These bindings live in the `sql` major-mode keymap, so `C-c C-c`, `C-c C-b`
and the EXPLAIN keys also work in **any `.sql` file buffer**, against the
configured URL — the Emacs `sql-mode` habit.

### Variables

psql variables work in the buffer: `:name`, `:'name'` (as a quoted literal)
and `:"name"` (as a quoted identifier). Before a run, every variable the SQL
references but doesn't `\set` itself is asked for in the minibuffer, pre-filled
with the value you gave last time, and passed to psql as `-v name=value`:

```sql
select * from dd_lease_review_decisions where deal_id = :'deal';
```

An empty answer leaves the variable unset. References inside strings,
comments, dollar quotes and `::` casts are ignored, as are psql's built-ins
(`:DBNAME`, `:USER`, …). A buffer that uses `\gset` is never prompted, since
its variables come from query results.

### History

Every query you run from the query pane is saved, newest first, to
`~/.config/macros/psql-history` (duplicates collapse to the newest copy; the
last 500 are kept). Queries the package runs itself, like `v` previews, are not
saved.

| Key              | Action                                                    |
| ---------------- | --------------------------------------------------------- |
| `up` / `down`    | in an **empty** query pane, recall the previous query; keep pressing to step older / newer (normal state, evil or helix) |
| `M-p` / `M-n`    | the same, in any state (insert, Emacs bindings)           |

Stepping continues while the pane still shows the recalled query untouched;
`down` past the newest empties the pane again. Once you edit the query, or the
pane wasn't empty to begin with, the arrows move the cursor as usual. Recall a
query, then `C-c C-c` to run it again.

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
newline or a `|` cannot break its row. Every row lands in the table. In the org
view (and for babel blocks), each result set is formatted as an **org-mode table**, cells clamped to 80 chars
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


## EXPLAIN

`C-c C-e` explains the region / statement at point; `C-c C-a` runs `EXPLAIN
(ANALYZE, BUFFERS)` on it — wrapped in `BEGIN … ROLLBACK`, so explaining an
`INSERT` / `UPDATE` / `DELETE` doesn't keep its changes (statements that can't
run in a transaction, like `CREATE INDEX CONCURRENTLY`, can't be explained this
way). The plan opens in `*psql-explain*` (in the other window from the query
pane):

```
EXPLAIN (ANALYZE, BUFFERS) — run inside BEGIN … ROLLBACK
select count(*) from c where x = 1 and y = 1
  Planning Time: 0.271 ms
  Execution Time: 2.878 ms

     SELF   SHARE
     33µs    1.1% ▏           Aggregate  (cost=2076.03..2076.04 rows=1 width=8) (actual time=2.824..2.825 rows=1 loops=1)
                                Buffers: shared hit=576
    2.7ms   98.8% █████████▉    ->  Seq Scan on c  (cost=0.00..2076.00 rows=11 width=0) (actual time=0.023..2.792 rows=1000 loops=1)  ▲ 1000 rows vs 11 estimated
                                      Filter: ((x = 1) AND (y = 1))
                                      Rows Removed by Filter: 99000
```

- Every plan node is a **foldable section** nested like the plan (`TAB` / `RET`),
  its details (filters, buffers, sort method, …) inside it.
- With ANALYZE, **SELF** is the node's own time — actual time × loops, minus
  its children's — and **SHARE** that time's part of the whole run, with a
  bar; a node over 20% is highlighted, over 50% in red. (Parallel workers make
  per-loop times approximate.)
- A node whose actual rows are **≥ 10× off the estimate** is flagged `▲` —
  stale statistics, or columns the planner doesn't know are correlated. Under
  a `Limit`, nodes stop early, so there only under-estimates are flagged.
- Planning / execution time and JIT lines sit at the top; the echo area shows
  the execution time.

`yy` copies a line, `Y` the plan, `q` closes. psql variables are prompted for
as with `C-c C-c`.

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

With point on a table, `?` offers table info / preview / copy / query / refresh; on a
schema heading, schema info / fold / copy; anywhere else, a view menu (refresh,
query, set URL, up).

## Notes / limitations

- Catalog output is parsed as unaligned `psql -A -t` tuples (no JSON parser in
  Steel). Every query keeps its single free-text column **last**, and the
  parser re-joins stray `|` separators into it, so a `|` inside an index or
  default expression can't shift columns. A `|` inside a *schema or table
  name* would still confuse the dashboard — don't do that.
- Row counts are planner estimates (`pg_class.reltuples`), not `count(*)`.
- Auto-refresh only fetches while the dashboard is the buffer in front (and
  drops a redraw that lands after you've left), so it never redraws a buffer
  you aren't looking at.
- SQL completion's very first catalog fetch (when nothing has rendered a
  dashboard yet) is synchronous; every later refresh happens in the
  background alongside the dashboard's.
- System schemas (`pg_*`, `information_schema`) are hidden.

## License

MIT — see [LICENSE](LICENSE).
