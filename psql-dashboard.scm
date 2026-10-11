;;; psql-dashboard — a PostgreSQL dashboard for the macros editor, in Steel.
;;;
;;; A magit-style porcelain for `psql`. The Rust core knows nothing about
;;; Postgres — the package sits on the same editor primitives magit / macros-k8s
;;; use:
;;;   * `call-process-full` — run psql, capture stdout/stderr (catalog queries)
;;;   * lib-async (`async-lane-run`) — run user queries WITHOUT freezing the UI,
;;;     cancellable with C-g
;;;   * lib-section (`section-open`/`section-line`/`section-render`) — foldable,
;;;     navigable read-only buffers
;;;   * `render-buffer` — the results / error buffers
;;;   * `split-window-below` + `set-major-mode "sql"` — the half-window query
;;;     pane, with real tree-sitter SQL highlighting
;;;   * lib-transient — the `?` popup
;;;
;;; Buffers and drill-down:
;;;   *psql-dashboard*        health header (connections, cache hit, TPS
;;;                           sparkline), Attention (things worth a look),
;;;                           Trends, Activity, then each schema's biggest
;;;                           relations with size bars. `a` auto-refreshes.
;;;                           RET / g on a schema heading → the schema buffer;
;;;                           RET / g on a table row      → the table buffer.
;;;   *psql-schema:S*         schema info + its tables with size breakdown
;;;                           (total / table / indexes). RET / g drills into a
;;;                           table; ^ goes back up to the dashboard.
;;;   *psql-table:S.T*        size bars, stats, columns (keys + planner stats),
;;;                           indexes, constraints (RET follows a foreign key),
;;;                           referenced-by (and the definition, for views).
;;;                           ^ goes up to the schema; v previews rows.
;;;   *psql-query*            an editable sql-mode buffer in a half-height pane
;;;                           (`s` from any dashboard buffer, or M-x psql-query).
;;;                           C-c C-c runs the buffer's SQL asynchronously;
;;;                           C-g cancels a running query; C-c C-k closes it.
;;;   psql-result.csv         the query output as a grid (errors / no rows →
;;;                           results.org instead).
;;;
;;; Conventions (matching macros-k8s / macros-jj):
;;;   * public commands are `psql-…`, private helpers `psql--…`
;;;   * ALL mutable runtime state lives in ONE hash, `psql-state`
;;;   * connection config lives in the editor's OPTION store (`psql-url`), not a
;;;     Scheme var, so `(set-option "psql-url" …)` in init.scm works regardless
;;;     of load order (see the macros-k8s README for why).
;;;
;;; psql output is parsed as unaligned tuples (`-A -t`, `|`-separated). Every
;;; query puts its only free-text column LAST, and the row parser re-joins any
;;; extra separators into that final field, so a `|` inside a default expression
;;; or index definition can't shift columns.
;;;
;;;   M-x psql-dashboard    open the dashboard (bind it yourself if you want a
;;;   key — this package adds no global bindings).

;; ── configuration ────────────────────────────────────────────────────────────
;; Both settings live in the editor's OPTION store so init.scm can set them
;; regardless of load order (a package's own `define` would clobber a pre-load
;; define, and set! can't reach across compilation units).
;;
;; The psql executable. The GUI editor does NOT inherit your shell PATH, so on
;; a Homebrew/Postgres.app machine you usually need an absolute path:
;;   (set-option "psql-command" "/opt/homebrew/opt/libpq/bin/psql")
(define (psql--command)
  (let ((v (get-option "psql-command")))
    (if (and (string? v) (not (equal? v ""))) v "psql")))

;; The connection URL:
;;   (set-option "psql-url" "postgres://user:pass@host:5432/dbname")
;; Empty / unset = psql's own defaults (PGHOST / PGDATABASE / ~/.pgpass etc.).
(define (psql--url)
  (let ((v (get-option "psql-url")))
    (if (string? v) v "")))

;; The URL can be a secret reference instead of a string:
;;   (set-option "psql-url" (secret-get "prod-read-only" ""))
;; `get-option` reads it as #f until authinfo.gpg is unlocked, so every command
;; that talks to the server runs through here first: `option-ensure` prompts for
;; the passphrase, then for the URL itself if there's no entry yet (offering to
;; save it). A plain or unset option runs `k` immediately.
;; The ensure can still come back without a value (e.g. saving to authinfo.gpg
;; failed), so check again rather than silently connecting to the PG* defaults.
(define (psql--with-url k)
  (option-ensure "psql-url"
                 (lambda ()
                   (if (psql--url-pending?)
                       (message (string-append "psql: no value for psql-url ("
                                               (option-secret-label "psql-url")
                                               ") — see *Messages* for authinfo errors"))
                       (k)))
                 'on-cancel (lambda (_) (message "psql: no connection URL — cancelled"))))
;; Synchronous callers (org-babel) can't prompt: #t while a referenced URL is
;; still locked away.
(define (psql--url-pending?)
  (and (option-secret-ref "psql-url") (not (get-option "psql-url"))))

;; ── faces ─────────────────────────────────────────────────────────────────────
;; User-overridable: redefine any of these in init.scm (re-apply after a
;; load-theme, which wipes the palette).
(set-face "psql-header"  "#66d9ef")   ; the database / connection line
(set-face "psql-section" "#a6e22e")   ; section headings
(set-face "psql-ok"      "#a6e22e")   ; active backends
(set-face "psql-warn"    "#e6db74")   ; idle in transaction, dead tuples
(set-face "psql-err"     "#f92672")   ; errors
(set-face "psql-dim"     "#888888")   ; column headers, hints, empty notes
(set-face "psql-bar"     "#ae81ff")   ; inline bars and sparklines

;; ── state ─────────────────────────────────────────────────────────────────────
(define psql-state
  (hash
   'linemaps  '()   ; buffer-name -> ((line kind schema name) …)
   'views     '()   ; buffer-name -> ("dashboard") | ("schema" S) | ("table" S T)
   'lm-buf    ""    ; the buffer currently being rendered (psql--record target)
   'async-out '()   ; reversed lines of the running user query's output
   'async-n   0     ; lines seen this run (cheap row-cap counter)
   'capped    #f    ; row cap hit → the run was auto-cancelled, not user-cancelled
   ;; completion catalog (see the SQL completion section)
   'cat-state ""    ; "" = unfetched · "ok" · "failed" (don't retry every key)
   'cat-schemas '() ; (schema …)
   'cat-tables  '() ; ((schema table) …)
   'cat-cols    '() ; "table" / "schema.table" -> (column …)
   ;; dashboard trends + auto-refresh
   'samples     '() ; ((ms xacts blks-hit blks-read active) …), oldest first
   'auto        #f  ; auto-refresh on?
   'timer-armed #f  ; is a tick scheduled?
   'quiet       #f  ; rendering from a tick (skip the catalog refresh)
   'pending-msg ""  ; echo-area summary shown after a results file opens
   ))
(define (psql--st key) (hash-try-get psql-state key))
(define (psql--st! key val) (set! psql-state (hash-insert psql-state key val)))

;; ── small helpers ─────────────────────────────────────────────────────────────
(define (psql--lines s)
  (filter (lambda (l) (not (equal? l ""))) (split-many s "\n")))
(define (psql--blank? s) (equal? (trim-end s) ""))
(define (psql--nth-or lst i default)
  (if (< i (length lst)) (nth lst i) default))
(define (psql--sum lst)
  (let loop ((l lst) (acc 0))
    (if (null? l) acc (loop (cdr l) (+ acc (car l))))))
;; Shell-quote for the /bin/sh -c async command line.
(define (psql--sh-quote s)
  (string-append "'" (string-join (split-many s "'") "'\\''") "'"))
;; Double single-quotes for embedding an identifier in a SQL string literal.
(define (psql--sq s)
  (string-join (split-many s "'") "''"))

;; Split a psql unaligned row into exactly `n` fields: the first n-1 columns are
;; taken as-is, everything after re-joins into the LAST field — so a `|` inside
;; the final (free-text) column can't shift the row.
(define (psql--fields-n row n)
  (let loop ((parts (split-many row "|")) (k (- n 1)) (acc '()))
    (if (or (= k 0) (null? (cdr parts)))
        (reverse (cons (string-join parts "|") acc))
        (loop (cdr parts) (- k 1) (cons (car parts) acc)))))

;; Redact the password in a connection URL for display:
;; postgres://user:secret@host/db → postgres://user:***@host/db
(define (psql--redact url)
  (if (not (string-contains? url "@"))
      url
      (let* ((at    (split-many url "@"))
             (pre   (car at))
             (rest  (string-join (cdr at) "@")))
        (if (string-contains? pre "://")
            (let* ((sp     (split-many pre "://"))
                   (scheme (car sp))
                   (creds  (string-join (cdr sp) "://")))
              (if (string-contains? creds ":")
                  (string-append scheme "://" (car (split-many creds ":")) ":***@" rest)
                  url))
            url))))
(define (psql--display-url)
  (let ((u (psql--url)))
    (if (equal? u "") "(PG* environment)" (psql--redact u))))

;; ── human-readable sizes / counts ─────────────────────────────────────────────
;; "x.y<unit>" from a value scaled to tenths (integer math — no floats needed).
(define (psql--tenths v unit-size unit)
  (let ((t (quotient (* v 10) unit-size)))
    (string-append (number->string (quotient t 10)) "."
                   (number->string (remainder t 10)) unit)))
(define (psql--human bytes)
  (cond ((< bytes 1024)       (string-append (number->string bytes) " B"))
        ((< bytes 1048576)    (psql--tenths bytes 1024 " KB"))
        ((< bytes 1073741824) (psql--tenths bytes 1048576 " MB"))
        (else                 (psql--tenths bytes 1073741824 " GB"))))
;; Row-count estimate: reltuples is -1 when never analyzed.
(define (psql--rows-h n)
  (cond ((< n 0)       "?")
        ((< n 1000)    (number->string n))
        ((< n 1000000) (psql--tenths n 1000 "k"))
        (else          (psql--tenths n 1000000 "M"))))
(define (psql--num s)
  (let ((n (string->number s))) (if n n -1)))

;; ── column alignment ──────────────────────────────────────────────────────────
;; Max width of each column across a list of cell-lists (rows must be same arity).
(define (psql--merge-widths ws cells)
  (cond ((null? cells) ws)
        ((null? ws) (map string-length cells))
        (else (cons (max (car ws) (string-length (car cells)))
                    (psql--merge-widths (cdr ws) (cdr cells))))))
(define (psql--widths rows)
  (let loop ((r rows) (ws '()))
    (if (null? r) ws (loop (cdr r) (psql--merge-widths ws (car r))))))
;; One row, each column padded to its width, two-space gutters; the last column
;; is left unpadded (it's the flexible one).
(define (psql--fmt cells ws)
  (cond ((null? cells) "")
        ((null? (cdr cells)) (car cells))
        (else (string-append (pad-right (car cells) (car ws)) "  "
                             (psql--fmt (cdr cells) (cdr ws))))))

;; ── psql plumbing ─────────────────────────────────────────────────────────────
(define (psql--conn)
  (let ((u (psql--url))) (if (equal? u "") '() (list "-d" u))))
(define (psql--run-full args) (call-process-full (psql--command) args ""))

;; The psql binary couldn't be started. call-process-full reports a spawn
;; failure as exit "-1" with the bare OS error ("No such file or directory");
;; the /bin/sh paths (query pane, babel) see the shell's exit 127 instead.
(define (psql--not-found? code) (or (equal? code "-1") (equal? code "127")))
(define (psql--not-found-msg)
  (string-append "psql: can't run \"" (psql--command) "\" — set the psql-command"
                 " option to your psql binary's full path (the GUI editor doesn't"
                 " inherit your shell PATH), e.g."
                 " (set-option \"psql-command\" \"/opt/homebrew/opt/libpq/bin/psql\")"))

(define (psql--error code stderr)
  (if (psql--not-found? code)
      (message (psql--not-found-msg))
      (begin
        (render-buffer "*psql-error*" "psql-result-mode"
                       (if (psql--blank? stderr) "psql failed (no output)" (trim-end stderr)) '())
        (message "psql failed — see *psql-error*"))))

;; Run `sql`, parse unaligned tuples into rows of exactly `ncols` fields.
;; → a list of rows, or #f after surfacing the error (callers abort on #f).
(define (psql--query sql ncols)
  (let ((r (psql--run-full (append (psql--conn)
                                   (list "-X" "-q" "-A" "-t" "-P" "pager=off" "-c" sql)))))
    (if (equal? (car r) "0")
        (map (lambda (ln) (psql--fields-n ln ncols)) (psql--lines (nth r 1)))
        (begin (psql--error (car r) (nth r 2)) #f))))
;; Raw stdout of `sql` (for multi-line single values like a view definition).
(define (psql--raw sql)
  (let ((r (psql--run-full (append (psql--conn)
                                   (list "-X" "-q" "-A" "-t" "-P" "pager=off" "-c" sql)))))
    (if (equal? (car r) "0") (trim-end (nth r 1)) #f)))

;; A scalar subselect resolving schema.table to its pg_class oid — safer than
;; ::regclass (no identifier-quoting games; names embed as escaped literals).
(define (psql--reloid s t)
  (string-append
   "(select c.oid from pg_class c join pg_namespace n on n.oid = c.relnamespace"
   " where n.nspname = '" (psql--sq s) "' and c.relname = '" (psql--sq t) "')"))

(define (psql--kind k)
  (cond ((equal? k "r") "table")
        ((equal? k "p") "part.table")
        ((equal? k "m") "matview")
        ((equal? k "v") "view")
        ((equal? k "f") "foreign")
        (else k)))
(define (psql--sizeless? k) (member k (list "v" "f")))

;; ── line map (what's on each rendered line, per buffer) ───────────────────────
(define (psql--alist-set alist key val)
  (cons (cons key val)
        (filter (lambda (kv) (not (equal? (car kv) key))) alist)))
(define (psql--lm-begin! buf)
  (psql--st! 'lm-buf buf)
  (psql--st! 'linemaps (psql--alist-set (psql--st 'linemaps) buf '())))
;; Record that the NEXT section-line holds `kind`/`schema`/`name`.
(define (psql--record kind schema name)
  (let* ((buf (psql--st 'lm-buf))
         (maps (psql--st 'linemaps))
         (cur (let ((e (alist-ref maps buf))) (if e e '()))))
    (psql--st! 'linemaps
               (psql--alist-set maps buf
                                (cons (list (section-point-line) kind schema name) cur)))))
;; The (line kind schema name) entry under point, or #f.
(define (psql--at)
  (let ((entries (alist-ref (psql--st 'linemaps) (current-buffer)))
        (ln (buffer-line)))
    (if entries
        (let loop ((m entries))
          (cond ((null? m) #f)
                ((= (car (car m)) ln) (car m))
                (else (loop (cdr m)))))
        #f)))

;; ── view tracking (what each buffer shows, so refresh / ^ work anywhere) ──────
(define (psql--view-set! buf v)
  (psql--st! 'views (psql--alist-set (psql--st 'views) buf v)))
(define (psql--view buf) (alist-ref (psql--st 'views) buf))

;; ── batched queries ───────────────────────────────────────────────────────────
;; A view needs several catalog queries, and every psql run is a fresh
;; connection (a TLS handshake, for a remote server). So a view's queries go out
;; as ONE psql process — `-c q1 -c SEP -c q2 -c SEP …` — and the output is split
;; back apart on the separator rows. psql keeps going past a failing -c (exit
;; 0, the error on stderr), so an optional query (pg_stat_statements on a
;; server without it) just comes back empty.
(define psql--sep "@@PSQL-SEP@@")
(define (psql--batch-args specs)
  (let loop ((ss specs) (acc '()))
    (if (null? ss)
        (reverse acc)
        (loop (cdr ss)
              (cons (string-append "select '" psql--sep "'")
                    (cons "-c" (cons (car (car ss)) (cons "-c" acc))))))))
(define (psql--split-batch lines)
  (let loop ((ls lines) (cur '()) (groups '()))
    (cond ((null? ls) (reverse (if (null? cur) groups (cons (reverse cur) groups))))
          ((equal? (car ls) psql--sep) (loop (cdr ls) '() (cons (reverse cur) groups)))
          (else (loop (cdr ls) (cons (car ls) cur) groups)))))

;; `specs` = ((sql ncols) …) → (rows-per-query error-lines), or #f after
;; surfacing a failure to run psql / connect at all.
(define (psql--batch specs)
  (let ((r (psql--run-full (append (psql--conn)
                                   (list "-X" "-q" "-A" "-t" "-P" "pager=off")
                                   (psql--batch-args specs)))))
    (if (not (equal? (car r) "0"))
        (begin (psql--error (car r) (nth r 2)) #f)
        (let ((groups (psql--split-batch (psql--lines (nth r 1)))))
          (list (let loop ((ss specs) (gs groups) (acc '()))
                  (if (null? ss)
                      (reverse acc)
                      (loop (cdr ss) (if (null? gs) '() (cdr gs))
                            (cons (map (lambda (ln) (psql--fields-n ln (cadr (car ss))))
                                       (if (null? gs) '() (car gs)))
                                  acc))))
                (filter (lambda (l) (starts-with? l "ERROR:"))
                        (split-many (nth r 2) "\n")))))))

;; ── display helpers ───────────────────────────────────────────────────────────
(define (psql--2d n) (if (< n 10) (string-append "0" (number->string n)) (number->string n)))
;; Seconds → "45s" · "12m03s" · "3h07m" · "2d4h"; "" for unknown (< 0).
(define (psql--dur secs)
  (cond ((< secs 0) "")
        ((< secs 60) (string-append (number->string secs) "s"))
        ((< secs 3600) (string-append (number->string (quotient secs 60)) "m"
                                      (psql--2d (remainder secs 60)) "s"))
        ((< secs 86400) (string-append (number->string (quotient secs 3600)) "h"
                                       (psql--2d (quotient (remainder secs 3600) 60)) "m"))
        (else (string-append (number->string (quotient secs 86400)) "d"
                             (number->string (quotient (remainder secs 86400) 3600)) "h"))))
;; Milliseconds → "850ms" or a duration.
(define (psql--ms ms)
  (if (< ms 1000) (string-append (number->string ms) "ms") (psql--dur (quotient ms 1000))))
;; a / (a + b) in permille, or -1 when there's nothing to divide.
(define (psql--ratio-pm a b)
  (if (> (+ a b) 0) (quotient (* a 1000) (+ a b)) -1))
;; Permille → "99.8%".
(define (psql--pct pm)
  (if (< pm 0)
      "-"
      (string-append (number->string (quotient pm 10)) "." (number->string (remainder pm 10)) "%")))
;; A cache-hit permille's face: healthy ≥ 99%, worrying < 95%.
(define (psql--hit-face pm)
  (cond ((< pm 0) "psql-dim") ((>= pm 990) "psql-ok") ((>= pm 950) "psql-warn") (else "psql-err")))
;; An inline bar (lib-plot glyphs, ⅛-cell resolution) padded to `width` cells,
;; so the columns after it stay aligned.
(define (psql--bar v mx width)
  (pad-right (if (and (> mx 0) (> v 0)) (textplot-hbar v mx width) "") width))
(define (psql--max-of nums) (if (null? nums) 0 (apply max nums)))
(define (psql--dash-rows) (psql--option-num "psql-dashboard-rows" 15))

;; ── aligned rows ──────────────────────────────────────────────────────────────
;; A cell is a string or (text face): faced cells become sub-line accents (bars,
;; markers) without coloring the whole line. The LAST cell is the free-text one:
;; past psql--wrap-width it wraps onto continuation lines indented under its
;; column, instead of soft-wrapping back to column 0.
(define psql--wrap-width 100)
(define (psql--cell-text c) (if (string? c) c (car c)))
(define (psql--cell-face c) (if (string? c) #f (cadr c)))

;; Greedy word wrap → lines (a single word longer than `w` stays whole).
(define (psql--wrap s w)
  (if (<= (string-length s) w)
      (list s)
      (let loop ((ws (split-many s " ")) (cur "") (acc '()))
        (cond ((null? ws) (reverse (if (equal? cur "") acc (cons cur acc))))
              ((equal? cur "") (loop (cdr ws) (car ws) acc))
              ((> (+ (string-length cur) 1 (string-length (car ws))) w)
               (loop ws "" (cons cur acc)))
              (else (loop (cdr ws) (string-append cur " " (car ws)) acc))))))

(define (psql--emit-row cells ws line-face)
  (let loop ((cs cells) (ws ws) (text "    ") (accents '()))
    (if (null? (cdr cs))
        (let* ((col (string-length text))
               (parts (psql--wrap (psql--cell-text (car cs)) psql--wrap-width))
               (start (utf8-length text))
               (first (string-append text (car parts)))
               (accents (if (psql--cell-face (car cs))
                            (cons (list start (utf8-length first) (psql--cell-face (car cs))) accents)
                            accents))
               (b (section-point-byte)))
          (section-line first line-face)
          (for-each (lambda (a) (section-accent (+ b (car a)) (+ b (cadr a)) (nth a 2))) accents)
          (for-each (lambda (p) (section-line (string-append (string-repeat " " col) p) line-face))
                    (cdr parts)))
        (let* ((t (pad-right (psql--cell-text (car cs)) (car ws)))
               (start (utf8-length text)))
          (loop (cdr cs) (cdr ws) (string-append text t "  ")
                (if (psql--cell-face (car cs))
                    (cons (list start (+ start (utf8-length t)) (psql--cell-face (car cs))) accents)
                    accents))))))

;; A column-aligned block: header row (dim) + one row per record. `cells-of`
;; maps a record to its display cells; `record-of` (or #f) is called per record
;; to register the row in the line map; `face-of` (or #f) picks a row face.
(define (psql--emit-rows header records cells-of record-of face-of)
  (let* ((cells (map cells-of records))
         (ws (psql--widths (map (lambda (r) (map psql--cell-text r)) (cons header cells)))))
    (psql--emit-row header ws "psql-dim")
    (let loop ((rs records) (cs cells))
      (when (not (null? rs))
        (when record-of (record-of (car rs)))
        (psql--emit-row (car cs) ws (if face-of (face-of (car rs)) #f))
        (loop (cdr rs) (cdr cs))))))

;; One line from (text face) segments, each faced segment an accent.
(define (psql--emit-segs segs line-face)
  (let ((b (section-point-byte)))
    (let loop ((ss segs) (off 0) (text ""))
      (if (null? ss)
          (section-line text line-face)
          (let* ((t (car (car ss))) (f (cadr (car ss))) (n (utf8-length t)))
            (when f (section-accent (+ b off) (+ b off n) f))
            (loop (cdr ss) (+ off n) (string-append text t)))))))
;; "    key         value" with a dim key.
(define (psql--kv key segs)
  (psql--emit-segs (cons (list (string-append "    " (pad-right key 12)) "psql-dim") segs) #f))

(define (psql--emit-hint text)
  (section-line (string-append "  " text) "psql-dim")
  (section-line "" #f))

;; Lib-plot rows, indented to sit under a section heading.
(define (psql--emit-plot p)
  (for-each
   (lambda (row)
     (let ((b (+ (section-point-byte) 4)))
       (section-line (string-append "    " (plot-row-text row)))
       (for-each (lambda (s) (section-accent (+ b (car s)) (+ b (cadr s)) (nth s 2)))
                 (plot-row-spans row))))
   p))

;; ── dashboard queries ─────────────────────────────────────────────────────────
(define psql--meta-sql
  (string-append
   "select current_database(), current_user, current_setting('server_version'),"
   " pg_database_size(current_database()), pg_is_in_recovery(),"
   " current_setting('max_connections'),"
   " coalesce(extract(epoch from now() - pg_postmaster_start_time())::bigint, -1)"))
;; Cumulative counters — rates come from the difference between two refreshes.
(define psql--dbstats-sql
  (string-append
   "select (extract(epoch from clock_timestamp()) * 1000)::bigint,"
   " d.xact_commit + d.xact_rollback, d.blks_hit, d.blks_read, d.deadlocks,"
   " d.temp_bytes, age(db.datfrozenxid)"
   " from pg_stat_database d join pg_database db on db.oid = d.datid"
   " where d.datname = current_database()"))
(define psql--conns-sql
  (string-append
   "select count(*), count(*) filter (where state = 'active'),"
   " count(*) filter (where state like 'idle in transaction%'),"
   " count(*) filter (where wait_event_type = 'Lock')"
   " from pg_stat_activity where datname = current_database()"
   " and backend_type = 'client backend'"))
;; All relations in user schemas. relname LAST (the free-text-ish column).
(define psql--tables-sql
  (string-append
   "select n.nspname, c.relkind, c.reltuples::bigint, pg_total_relation_size(c.oid), c.relname"
   " from pg_class c join pg_namespace n on n.oid = c.relnamespace"
   " where c.relkind in ('r','p','m','v','f')"
   " and left(n.nspname,3) <> 'pg_' and n.nspname <> 'information_schema'"
   " order by n.nspname, pg_total_relation_size(c.oid) desc, c.relname"))
;; Every user schema with its owner (so empty schemas still show).
(define psql--schemas-sql
  (string-append
   "select pg_get_userbyid(n.nspowner), n.nspname from pg_namespace n"
   " where left(n.nspname,3) <> 'pg_' and n.nspname <> 'information_schema'"
   " order by n.nspname"))
;; Non-idle client sessions, longest-running first.
(define psql--activity-sql
  (string-append
   "select a.pid, coalesce(a.usename,''), coalesce(a.state,''),"
   " coalesce(a.wait_event_type || ':' || a.wait_event, ''),"
   " coalesce(extract(epoch from now() - coalesce(a.query_start, a.backend_start))::bigint, -1),"
   " array_to_string(pg_blocking_pids(a.pid), ','),"
   " left(regexp_replace(coalesce(a.query,''), '\\s+', ' ', 'g'), 200)"
   " from pg_stat_activity a"
   " where a.datname = current_database() and a.pid <> pg_backend_pid()"
   " and a.backend_type = 'client backend' and coalesce(a.state,'') <> 'idle'"
   " order by a.query_start nulls last"))
;; Things worth a look, as (severity check schema relation detail). Severity is
;; err / warn / info; `ord` puts live problems (blocking, long queries) first.
(define psql--attention-sql
  (string-append
   "select sev, kind, sch, rel, detail from ("
   ;; sessions
   " select 'err' sev, 'blocked' kind, '' sch, '' rel,"
   "  'pid ' || pid || ' (' || coalesce(usename,'') || ') waiting on pid '"
   "  || array_to_string(pg_blocking_pids(pid), ',') detail, 0 ord"
   "  from pg_stat_activity where datname = current_database()"
   "  and cardinality(pg_blocking_pids(pid)) > 0"
   " union all"
   " select 'err', 'long query', '', '',"
   "  'pid ' || pid || ' (' || coalesce(usename,'') || ') running for '"
   "  || date_trunc('second', now() - query_start)::text, 1"
   "  from pg_stat_activity where datname = current_database() and state = 'active'"
   "  and pid <> pg_backend_pid() and now() - query_start > interval '5 minutes'"
   " union all"
   " select 'err', 'idle in xact', '', '',"
   "  'pid ' || pid || ' (' || coalesce(usename,'') || ') idle in transaction for '"
   "  || date_trunc('second', now() - state_change)::text || ' — holds locks, blocks vacuum', 1"
   "  from pg_stat_activity where datname = current_database()"
   "  and state like 'idle in transaction%' and now() - state_change > interval '1 minute'"
   " union all"
   " select 'warn', 'xid age', '', '',"
   "  'transaction ID age ' || age(datfrozenxid)::text || ' (wraparound at ~2.1B)', 1"
   "  from pg_database where datname = current_database() and age(datfrozenxid) > 500000000"
   ;; tables
   " union all"
   " select 'warn', 'dead tuples', schemaname, relname,"
   "  n_dead_tup::text || ' dead rows (' || (n_dead_tup * 100 / greatest(n_live_tup + n_dead_tup, 1))::text"
   "  || '%) · last vacuum ' || coalesce(date_trunc('second', greatest(last_vacuum, last_autovacuum))::text, 'never'), 2"
   "  from pg_stat_user_tables where n_dead_tup > 1000 and n_dead_tup * 5 > n_live_tup"
   " union all"
   " select 'warn', 'empty but big', schemaname, relname,"
   "  pg_size_pretty(pg_table_size(relid)) || ' on disk with ~0 live rows — bloat (VACUUM FULL)', 3"
   "  from pg_stat_user_tables where n_live_tup = 0 and pg_table_size(relid) > 10485760"
   " union all"
   " select 'info', 'seq scans', schemaname, relname,"
   "  seq_scan::text || ' seq scans reading ~' || (seq_tup_read / greatest(seq_scan, 1))::text"
   "  || ' rows each vs ' || coalesce(idx_scan, 0)::text || ' index scans — missing index?', 4"
   "  from pg_stat_user_tables where seq_scan > 100 and n_live_tup > 10000"
   "  and seq_tup_read / greatest(seq_scan, 1) > 10000 and seq_scan > coalesce(idx_scan, 0)"
   " union all"
   " select 'info', 'unused index', s.schemaname, s.relname,"
   "  s.indexrelname || ' · ' || pg_size_pretty(pg_relation_size(s.indexrelid)) || ' · 0 scans', 5"
   "  from pg_stat_user_indexes s join pg_index i on i.indexrelid = s.indexrelid"
   "  where s.idx_scan = 0 and not i.indisunique and not i.indisprimary"
   "  and pg_relation_size(s.indexrelid) > 1048576"
   ;; never-analyzed: listed when they're big enough to matter; the (usually
   ;; many) small ones — autovacuum skips tables that barely change — as one row
   " union all"
   " select 'info', 'not analyzed', n.nspname, c.relname,"
   "  'no planner statistics — row estimates unknown (ANALYZE)', 6"
   "  from pg_class c join pg_namespace n on n.oid = c.relnamespace"
   "  where c.relkind in ('r','p','m') and c.reltuples < 0"
   "  and pg_total_relation_size(c.oid) > 1048576"
   "  and left(n.nspname,3) <> 'pg_' and n.nspname <> 'information_schema'"
   " union all"
   " select 'info', 'not analyzed', '', '',"
   "  count(*)::text || ' small tables (< 1 MB) never analyzed — their ~ROWS show ?', 7"
   "  from pg_class c join pg_namespace n on n.oid = c.relnamespace"
   "  where c.relkind in ('r','p','m') and c.reltuples < 0"
   "  and pg_total_relation_size(c.oid) <= 1048576"
   "  and left(n.nspname,3) <> 'pg_' and n.nspname <> 'information_schema'"
   "  having count(*) > 0"
   ") x order by ord, sch, rel, detail"))
;; Top statements by total time — only when pg_stat_statements is installed
;; (otherwise this query errors and the section is skipped).
(define psql--pgss-sql
  (string-append
   "select s.calls, round(s.total_exec_time)::bigint, round(s.mean_exec_time)::bigint, s.rows,"
   " left(regexp_replace(s.query, '\\s+', ' ', 'g'), 200)"
   " from pg_stat_statements s"
   " where s.dbid = (select oid from pg_database where datname = current_database())"
   " order by s.total_exec_time desc limit 10"))

;; ── samples (trends) ──────────────────────────────────────────────────────────
;; Each dashboard render appends (ms xacts blks-hit blks-read active) from the
;; cumulative counters; rates are the differences between neighbours. A stats
;; reset (counters going backwards) just drops that interval.
(define psql--max-samples 60)
(define (psql--sample! s)
  (let ((xs (append (psql--st 'samples) (list s))))
    (psql--st! 'samples (if (> (length xs) psql--max-samples) (cdr xs) xs))))
;; → ((tps hit-permille active) …), oldest first.
(define (psql--rates)
  (let loop ((xs (psql--st 'samples)) (acc '()))
    (if (or (null? xs) (null? (cdr xs)))
        (reverse acc)
        (let* ((a (car xs)) (b (cadr xs))
               (dms (- (car b) (car a)))
               (dx (- (nth b 1) (nth a 1))))
          (loop (cdr xs)
                (if (and (> dms 0) (>= dx 0))
                    (cons (list (quotient (* dx 1000) dms)
                                (psql--ratio-pm (- (nth b 2) (nth a 2)) (- (nth b 3) (nth a 3)))
                                (nth b 4))
                          acc)
                    acc))))))

;; ── dashboard rendering ───────────────────────────────────────────────────────
(define (psql--activity-face a)
  (let ((state (psql--nth-or a 2 "")))
    (cond ((not (equal? (psql--nth-or a 5 "") "")) "psql-err")   ; blocked
          ((string-contains? state "idle in transaction") "psql-warn")
          ((equal? state "active") "psql-ok")
          (else "psql-dim"))))
(define (psql--sev-face sev)
  (cond ((equal? sev "err") "psql-err") ((equal? sev "warn") "psql-warn") (else #f)))

(define (psql--emit-dash-header m db c)
  (let* ((maxc (psql--num (psql--nth-or m 5 "0")))
         (total (psql--num (psql--nth-or c 0 "0")))
         (hit (if (null? db) -1 (psql--ratio-pm (psql--num (nth db 2)) (psql--num (nth db 3)))))
         (rates (psql--rates))
         (tps (map car rates)))
    (section-line (string-append "Database: " (psql--nth-or m 0 "?")
                                 "   PostgreSQL " (psql--nth-or m 2 "?")
                                 (if (equal? (psql--nth-or m 4 "f") "t") "   [replica]" "")
                                 "   " (psql--display-url)
                                 (if (psql--st 'auto)
                                     (string-append "   [auto-refresh "
                                                    (number->string (quotient (psql--auto-ms) 1000)) "s]")
                                     ""))
                  "psql-header")
    (psql--emit-segs
     (list (list (string-append "Size: " (psql--human (psql--num (psql--nth-or m 3 "0")))
                                "   User: " (psql--nth-or m 1 "?")
                                "   Up: " (psql--dur (psql--num (psql--nth-or m 6 "-1")))
                                "   Connections: " (number->string total) "/" (number->string maxc) " ")
                 #f)
           (list (psql--bar total maxc 10) "psql-bar")
           (list (string-append " " (psql--nth-or c 1 "?") " active · "
                                (psql--nth-or c 2 "?") " idle in xact · "
                                (psql--nth-or c 3 "?") " waiting on locks")
                 #f))
     #f)
    (psql--emit-segs
     (append
      (list (list "Cache hit: " #f)
            (list (psql--pct hit) (psql--hit-face hit))
            (list " " #f)
            (list (psql--bar (max hit 0) 1000 10) "psql-bar")
            (list "   TPS: " #f))
      (cond ((null? tps)
             (list (list "(r refreshes add samples · a auto-refreshes)" "psql-dim")))
            ((null? (cdr tps))
             (list (list (string-append (number->string (car tps)) "/s") #f)))
            (else
             (list (list (textplot-sparkline tps 0 (max 1 (psql--max-of tps))) "psql-bar")
                   (list (string-append " " (number->string (car (reverse tps))) "/s") #f))))
      (if (null? db)
          '()
          (list (list (string-append "   Deadlocks: " (nth db 4)
                                     "   Temp: " (psql--human (psql--num (nth db 5))))
                      #f))))
     #f)
    (psql--emit-hint (string-append "r refresh · a auto · RET/g open · v preview rows · TAB fold · "
                                    "s query · U url · Y copy · ? menu · q quit"))))

;; "schema.rel", or "-" for a database-wide finding.
(define (psql--qual s t) (if (equal? t "") "-" (string-append s "." t)))

(define (psql--emit-attention rows)
  (section-open "psql/attention"
                (string-append "Attention (" (number->string (length rows)) ")")
                "psql-section")
  (if (null? rows)
      (section-line "    ✓ nothing to flag" "psql-ok")
      (psql--emit-rows (list "" "CHECK" "RELATION" "DETAIL")
                       rows
                       (lambda (r)
                         (let ((sev (nth r 0)))
                           (list (list (if (equal? sev "info") "·" "▲")
                                       (if (psql--sev-face sev) (psql--sev-face sev) "psql-dim"))
                                 (nth r 1) (psql--qual (nth r 2) (nth r 3)) (nth r 4))))
                       (lambda (r) (unless (equal? (nth r 3) "")
                                     (psql--record "table" (nth r 2) (nth r 3))))
                       (lambda (r) (if (equal? (nth r 0) "err") "psql-err" #f))))
  (section-close "psql/attention")
  (section-line "" #f))

;; TPS over the samples so far (appears from the third refresh on).
(define (psql--emit-trends)
  (let ((tps (map car (psql--rates))))
    (when (>= (length tps) 3)
      (section-open "psql/trends" "Trends" "psql-section")
      (psql--emit-plot
       (plot-lines (list (list "TPS" tps))
                   'width 60 'height 6 'y-min 0 'legend #f
                   'title (string-append "transactions/s · last " (number->string (length tps))
                                         " intervals")))
      (section-close "psql/trends")
      (section-line "" #f))))

(define (psql--emit-activity act)
  (section-open 'psql-activity
                (string-append "Activity (" (number->string (length act)) " non-idle)")
                "psql-section")
  (if (null? act)
      (section-line "    (no other non-idle sessions)" "psql-dim")
      (psql--emit-rows (list "PID" "USER" "STATE" "WAIT" "TIME" "BLOCKED BY" "QUERY")
                       act
                       (lambda (a) (list (nth a 0) (nth a 1) (nth a 2) (nth a 3)
                                         (psql--dur (psql--num (nth a 4))) (nth a 5) (nth a 6)))
                       #f
                       psql--activity-face))
  (section-close 'psql-activity)
  (section-line "" #f))

(define (psql--emit-top-queries rows)
  (unless (null? rows)
    (section-open "psql/top-queries" "Top queries (pg_stat_statements, by total time)" "psql-section")
    (let ((mx (psql--max-of (map (lambda (r) (psql--num (nth r 1))) rows))))
      (psql--emit-rows (list "CALLS" "TOTAL" "" "MEAN" "ROWS" "QUERY")
                       rows
                       (lambda (r) (list (nth r 0) (psql--ms (psql--num (nth r 1)))
                                         (list (psql--bar (psql--num (nth r 1)) mx 10) "psql-bar")
                                         (psql--ms (psql--num (nth r 2))) (nth r 3) (nth r 4)))
                       #f #f))
    (section-close "psql/top-queries")
    (section-line "" #f)))

;; One schema's foldable section: its biggest relations (psql-dashboard-rows,
;; default 15) with a size bar, then a "… N more" line that opens the schema.
;; `rows` are (kind tuples bytes name), already size-sorted by the SQL.
(define (psql--emit-schema s owner rows)
  (let* ((sizes (map (lambda (r) (nth r 2)) rows))
         (mx (psql--max-of sizes))
         (shown (psql--take rows (psql--dash-rows)))
         (more (- (length rows) (length shown))))
    (psql--record "schema" s "")
    (section-open (string-append "psql/" s)
                  (string-append s "  (" (number->string (length rows)) " relations · "
                                 (psql--human (psql--sum sizes)) " · " owner ")")
                  "psql-section")
    (if (null? rows)
        (section-line "    (no relations)" "psql-dim")
        (begin
          (psql--emit-rows
           (list "NAME" "TYPE" "~ROWS" "SIZE" "")
           shown
           (lambda (r)
             (if (psql--sizeless? (nth r 0))
                 (list (nth r 3) (psql--kind (nth r 0)) "-" "-" "")
                 (list (nth r 3) (psql--kind (nth r 0)) (psql--rows-h (nth r 1))
                       (psql--human (nth r 2)) (list (psql--bar (nth r 2) mx 16) "psql-bar"))))
           (lambda (r) (psql--record "table" s (nth r 3)))
           #f)
          (when (> more 0)
            (psql--record "schema" s "")
            (section-line (string-append "    … " (number->string more) " more — RET opens " s)
                          "psql-dim"))))
    (section-close (string-append "psql/" s))
    (section-line "" #f)))

(define (psql--render-dashboard)
  (let ((res (psql--batch (list (list psql--meta-sql 7) (list psql--dbstats-sql 7)
                                (list psql--conns-sql 4) (list psql--tables-sql 5)
                                (list psql--schemas-sql 2) (list psql--activity-sql 7)
                                (list psql--attention-sql 5) (list psql--pgss-sql 5)))))
    (when res   ; #f = couldn't run psql / connect, already surfaced
      (let* ((qs (car res))
             ;; pg_stat_statements missing is expected, not an error
             (errs (filter (lambda (e) (not (string-contains? e "pg_stat_statements"))) (cadr res)))
             (meta (nth qs 0)))
        (if (null? meta)
            (psql--error "1" (string-join (cadr res) "\n"))
            (let* ((m (car meta))
                   (db (if (null? (nth qs 1)) '() (car (nth qs 1))))
                   (c (if (null? (nth qs 2)) (list "?" "?" "?" "?") (car (nth qs 2))))
                   (tabs (nth qs 3))
                   (act (nth qs 5))
                   (line (if (equal? (current-buffer) "*psql-dashboard*") (buffer-line) 0)))
              (unless (null? db)
                (psql--sample! (list (psql--num (nth db 0)) (psql--num (nth db 1))
                                     (psql--num (nth db 2)) (psql--num (nth db 3))
                                     (psql--num (psql--nth-or c 1 "0")))))
              (psql--lm-begin! "*psql-dashboard*")
              (psql--view-set! "*psql-dashboard*" (list "dashboard"))
              (section-begin)
              (psql--emit-dash-header m db c)
              (psql--emit-attention
               (append (nth qs 6)
                       (let ((hit (if (null? db) -1
                                      (psql--ratio-pm (psql--num (nth db 2)) (psql--num (nth db 3))))))
                         (if (and (>= hit 0) (< hit 990))
                             (list (list "warn" "cache hit" "" ""
                                         (string-append (psql--pct hit) " of reads served from"
                                                        " shared buffers — working set may exceed"
                                                        " shared_buffers")))
                             '()))
                       (map (lambda (e) (list "warn" "query error" "" "" e)) errs)))
              (psql--emit-trends)
              (psql--emit-activity act)
              (psql--emit-top-queries (nth qs 7))
              (for-each
               (lambda (srow)
                 (let* ((owner (psql--nth-or srow 0 ""))
                        (s     (psql--nth-or srow 1 ""))
                        (rows  (map (lambda (r) (list (psql--nth-or r 1 "")
                                                      (psql--num (psql--nth-or r 2 "-1"))
                                                      (psql--num (psql--nth-or r 3 "0"))
                                                      (psql--nth-or r 4 "")))
                                    (filter (lambda (r) (equal? (psql--nth-or r 0 "") s)) tabs))))
                   (psql--emit-schema s owner rows)))
               (nth qs 4))
              (section-render "*psql-dashboard*" "psql-mode")
              (goto-line line)
              ;; piggy-back: refresh the SQL completion catalog — but not on
              ;; every auto-refresh tick (it's a whole pg_attribute scan)
              (unless (psql--st 'quiet) (psql--catalog-refresh!))))))))

;; ── schema buffer ─────────────────────────────────────────────────────────────
(define (psql--schema-buffer s) (string-append "*psql-schema:" s "*"))

(define (psql--render-schema s)
  (let* ((sq (psql--sq s))
         (res (psql--batch
               (list
                (list (string-append "select pg_get_userbyid(n.nspowner),"
                                     " regexp_replace(coalesce(obj_description(n.oid,'pg_namespace'),''), '\\s+', ' ', 'g')"
                                     " from pg_namespace n where n.nspname = '" sq "'") 2)
                (list (string-append
                       "select c.relkind, c.reltuples::bigint, pg_total_relation_size(c.oid),"
                       " pg_table_size(c.oid), pg_indexes_size(c.oid),"
                       " coalesce((st.n_dead_tup * 100 / nullif(st.n_live_tup + st.n_dead_tup, 0))::text, ''),"
                       " c.relname"
                       " from pg_class c join pg_namespace n on n.oid = c.relnamespace"
                       " left join pg_stat_all_tables st on st.relid = c.oid"
                       " where n.nspname = '" sq "' and c.relkind in ('r','p','m','v','f')"
                       " order by pg_total_relation_size(c.oid) desc, c.relname") 7)))))
    (when res
      (let ((info (car (car res))) (tabs (cadr (car res))))
        (if (null? info)
            (message (string-append "psql: no such schema — " s))
            (let* ((buf   (psql--schema-buffer s))
                   (owner (psql--nth-or (car info) 0 ""))
                   (desc  (psql--nth-or (car info) 1 ""))
                   (rows  (map (lambda (r) (list (psql--nth-or r 0 "")
                                                 (psql--num (psql--nth-or r 1 "-1"))
                                                 (psql--num (psql--nth-or r 2 "0"))
                                                 (psql--num (psql--nth-or r 3 "0"))
                                                 (psql--num (psql--nth-or r 4 "0"))
                                                 (psql--nth-or r 5 "")
                                                 (psql--nth-or r 6 "")))
                               tabs))
                   (mx (psql--max-of (map (lambda (r) (nth r 2)) rows)))
                   (line (if (equal? (current-buffer) buf) (buffer-line) 0)))
              (psql--lm-begin! buf)
              (psql--view-set! buf (list "schema" s))
              (section-begin)
              (section-line (string-append "Schema: " s "   Owner: " owner "   "
                                           (number->string (length rows)) " relations · "
                                           (psql--human (psql--sum (map (lambda (r) (nth r 2)) rows))))
                            "psql-header")
              (when (not (equal? desc "")) (section-line desc "psql-dim"))
              (psql--emit-hint "RET/g table info · v preview rows · ^ dashboard · r refresh · s query · Y copy · q quit")
              (section-open (string-append "psql-relations/" s) "Relations" "psql-section")
              (if (null? rows)
                  (section-line "    (no relations)" "psql-dim")
                  (psql--emit-rows
                   (list "NAME" "TYPE" "~ROWS" "TOTAL" "TABLE" "INDEXES" "DEAD" "")
                   rows
                   (lambda (r)
                     (if (psql--sizeless? (nth r 0))
                         (list (nth r 6) (psql--kind (nth r 0)) "-" "-" "-" "-" "" "")
                         (list (nth r 6) (psql--kind (nth r 0)) (psql--rows-h (nth r 1))
                               (psql--human (nth r 2)) (psql--human (nth r 3))
                               (psql--human (nth r 4))
                               (if (equal? (nth r 5) "")
                                   ""
                                   (list (string-append (nth r 5) "%")
                                         (if (>= (psql--num (nth r 5)) 20) "psql-warn" #f)))
                               (list (psql--bar (nth r 2) mx 16) "psql-bar"))))
                   (lambda (r) (psql--record "table" s (nth r 6)))
                   #f))
              (section-close (string-append "psql-relations/" s))
              (section-render buf "psql-mode")
              (goto-line line)))))))

;; ── table buffer ──────────────────────────────────────────────────────────────
(define (psql--table-buffer s t) (string-append "*psql-table:" s "." t "*"))
(define (psql--contype c)
  (cond ((equal? c "p") "primary key")
        ((equal? c "f") "foreign key")
        ((equal? c "u") "unique")
        ((equal? c "c") "check")
        ((equal? c "x") "exclusion")
        (else c)))

;; Free text squeezed onto one line and made safe as a non-final field.
(define (psql--flat-sql expr)
  (string-append "replace(regexp_replace(coalesce(" expr ", ''), '\\s+', ' ', 'g'), '|', '¦')"))

;; The table view's queries, in one batch (see psql--batch).
(define (psql--table-specs oid)
  (list
   ;; 0 overview
   (list (string-append
          "select c.relkind, pg_get_userbyid(c.relowner), c.reltuples::bigint,"
          " pg_total_relation_size(c.oid), pg_relation_size(c.oid), pg_table_size(c.oid),"
          " pg_indexes_size(c.oid), " (psql--flat-sql "obj_description(c.oid, 'pg_class')")
          " from pg_class c where c.oid = " oid) 8)
   ;; 1 activity counters
   (list (string-append
          "select coalesce(seq_scan,0), coalesce(idx_scan,0), coalesce(n_live_tup,0), coalesce(n_dead_tup,0),"
          " coalesce(n_tup_ins,0), coalesce(n_tup_upd,0), coalesce(n_tup_del,0), coalesce(n_tup_hot_upd,0),"
          " coalesce(date_trunc('second', greatest(last_vacuum, last_autovacuum))::text, 'never'),"
          " coalesce(date_trunc('second', greatest(last_analyze, last_autoanalyze))::text, 'never')"
          " from pg_stat_all_tables where relid = " oid) 10)
   ;; 2 cache
   (list (string-append
          "select coalesce(heap_blks_hit,0), coalesce(heap_blks_read,0),"
          " coalesce(idx_blks_hit,0), coalesce(idx_blks_read,0)"
          " from pg_statio_all_tables where relid = " oid) 4)
   ;; 3 columns, with keys and planner stats (pg_stats: needs SELECT on the table)
   (list (string-append
          "select a.attnum, format_type(a.atttypid, a.atttypmod),"
          " case when a.attnotnull then 'not null' else '' end,"
          " concat_ws(',',"
          "  case when exists (select 1 from pg_constraint k where k.conrelid = a.attrelid"
          "   and k.contype = 'p' and a.attnum = any(k.conkey)) then 'PK' end,"
          "  case when exists (select 1 from pg_constraint k where k.conrelid = a.attrelid"
          "   and k.contype = 'f' and a.attnum = any(k.conkey)) then 'FK' end,"
          "  case when exists (select 1 from pg_constraint k where k.conrelid = a.attrelid"
          "   and k.contype = 'u' and a.attnum = any(k.conkey)) then 'UQ' end,"
          "  case when exists (select 1 from pg_index i where i.indrelid = a.attrelid"
          "   and a.attnum = any(i.indkey::int2[])) then 'IDX' end),"
          " coalesce(round((s.null_frac * 100)::numeric, 1)::text || '%', ''),"
          " case when s.n_distinct is null then ''"
          "  when s.n_distinct = -1 then 'unique'"
          "  when s.n_distinct < 0 then round((-s.n_distinct * 100)::numeric)::text || '% of rows'"
          "  else s.n_distinct::bigint::text end,"
          " coalesce(s.avg_width::text, ''),"
          " " (psql--flat-sql "col_description(a.attrelid, a.attnum)") ","
          " a.attname, " (psql--flat-sql "pg_get_expr(d.adbin, d.adrelid)")
          " from pg_attribute a"
          " join pg_class c on c.oid = a.attrelid join pg_namespace n on n.oid = c.relnamespace"
          " left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum"
          " left join pg_stats s on s.schemaname = n.nspname and s.tablename = c.relname"
          "  and s.attname = a.attname"
          " where a.attrelid = " oid " and a.attnum > 0 and not a.attisdropped"
          " order by a.attnum") 10)
   ;; 4 indexes
   (list (string-append
          "select pg_relation_size(i.indexrelid), coalesce(st.idx_scan, 0),"
          " case when i.indisprimary or i.indisunique then 'u' else '' end,"
          " ic.relname, pg_get_indexdef(i.indexrelid)"
          " from pg_index i join pg_class ic on ic.oid = i.indexrelid"
          " left join pg_stat_all_indexes st on st.indexrelid = i.indexrelid"
          " where i.indrelid = " oid
          " order by pg_relation_size(i.indexrelid) desc, ic.relname") 5)
   ;; 5 constraints (FKs carry their target, so RET can follow them)
   (list (string-append
          "select con.contype, con.conname, coalesce(fn.nspname, ''), coalesce(fc.relname, ''),"
          " " (psql--flat-sql "pg_get_constraintdef(con.oid)")
          " from pg_constraint con"
          " left join pg_class fc on fc.oid = con.confrelid"
          " left join pg_namespace fn on fn.oid = fc.relnamespace"
          " where con.conrelid = " oid
          " order by con.contype, con.conname") 5)
   ;; 6 incoming foreign keys
   (list (string-append
          "select n.nspname, c.relname, con.conname, " (psql--flat-sql "pg_get_constraintdef(con.oid)")
          " from pg_constraint con join pg_class c on c.oid = con.conrelid"
          " join pg_namespace n on n.oid = c.relnamespace"
          " where con.confrelid = " oid " and con.contype = 'f'"
          " order by n.nspname, c.relname, con.conname") 4)))

;; Sections are keyed per table, so folding Columns in one table doesn't fold
;; it in every other table too.
(define (psql--tsec s t name) (string-append "psql-" name "/" s "." t))

(define (psql--emit-table-size o)
  (let* ((total (psql--num (psql--nth-or o 3 "0")))
         (heap (psql--num (psql--nth-or o 4 "0")))
         (toast (max 0 (- (psql--num (psql--nth-or o 5 "0")) heap)))
         (idx (psql--num (psql--nth-or o 6 "0")))
         (parts (list (list "heap" heap) (list "toast" toast) (list "indexes" idx))))
    (psql--emit-rows (list "" "" "SIZE" "SHARE")
                     parts
                     (lambda (p) (list (car p)
                                       (list (psql--bar (cadr p) total 30) "psql-bar")
                                       (psql--human (cadr p))
                                       (psql--pct (if (> total 0) (quotient (* (cadr p) 1000) total) -1))))
                     #f #f)))

(define (psql--emit-table-stats st io)
  (let* ((n (lambda (i) (psql--num (psql--nth-or st i "0"))))
         (live (n 2)) (dead (n 3)) (upd (n 5)) (seq (n 0)) (idx (n 1))
         (dead-pm (psql--ratio-pm dead live))
         (heap-hit (psql--ratio-pm (psql--num (psql--nth-or io 0 "0")) (psql--num (psql--nth-or io 1 "0"))))
         (idx-hit (psql--ratio-pm (psql--num (psql--nth-or io 2 "0")) (psql--num (psql--nth-or io 3 "0")))))
    (psql--kv "rows" (list (list (string-append "live " (number->string live) " · dead "
                                                (number->string dead) " (") #f)
                           (list (psql--pct dead-pm) (if (>= dead-pm 200) "psql-warn" #f))
                           (list ")" #f)))
    (psql--kv "writes" (list (list (string-append "ins " (psql--nth-or st 4 "0")
                                                  " · upd " (number->string upd)
                                                  " (HOT " (psql--pct (psql--ratio-pm (n 7) (- upd (n 7))))
                                                  ") · del " (psql--nth-or st 6 "0"))
                                   #f)))
    (psql--kv "scans" (list (list (string-append "seq " (number->string seq) " · idx "
                                                 (number->string idx) "  ") #f)
                            (list (psql--bar idx (+ seq idx) 10) "psql-bar")
                            (list (string-append " " (psql--pct (psql--ratio-pm idx seq)) " via index") #f)))
    (psql--kv "cache hit" (list (list "heap " #f)
                                (list (psql--pct heap-hit) (psql--hit-face heap-hit))
                                (list " · indexes " #f)
                                (list (psql--pct idx-hit) (psql--hit-face idx-hit))))
    (psql--kv "maintenance" (list (list (string-append "vacuum " (psql--nth-or st 8 "-")
                                                       " · analyze " (psql--nth-or st 9 "-"))
                                        #f)))))

(define (psql--emit-columns s t cols)
  (section-open (psql--tsec s t "columns")
                (string-append "Columns (" (number->string (length cols)) ")")
                "psql-section")
  (if (null? cols)
      (section-line "    (none)" "psql-dim")
      (let* ((rows (map (lambda (c)
                          ;; c = (attnum type notnull keys nulls distinct width comment name default)
                          (list (list (nth c 0) (nth c 8) (nth c 1)
                                      (list (nth c 3) "psql-header")
                                      (nth c 2) (nth c 4) (nth c 5) (nth c 6) (nth c 9))
                                (nth c 7)))
                        cols))
             (ws (psql--widths (map (lambda (r) (map psql--cell-text (car r)))
                                    (cons (list (list "#" "NAME" "TYPE" "KEY" "NULL" "NULLS"
                                                      "DISTINCT" "WIDTH" "DEFAULT"))
                                          rows)))))
        (psql--emit-row (list "#" "NAME" "TYPE" "KEY" "NULL" "NULLS" "DISTINCT" "WIDTH" "DEFAULT")
                        ws "psql-dim")
        (for-each (lambda (r)
                    (psql--emit-row (car r) ws #f)
                    ;; the column's comment, under its name
                    (unless (equal? (cadr r) "")
                      (section-line (string-append "    " (string-repeat " " (+ (car ws) 2))
                                                   "— " (cadr r))
                                    "psql-dim")))
                  rows)))
  (section-close (psql--tsec s t "columns"))
  (section-line "" #f))

(define (psql--emit-indexes s t idxs)
  (section-open (psql--tsec s t "indexes")
                (string-append "Indexes (" (number->string (length idxs)) ")")
                "psql-section")
  (if (null? idxs)
      (section-line "    (none)" "psql-dim")
      (let ((mx (psql--max-of (map (lambda (i) (psql--num (nth i 1))) idxs))))
        (psql--emit-rows (list "NAME" "SIZE" "SCANS" "" "DEFINITION")
                         idxs
                         (lambda (i)
                           (let ((scans (psql--num (nth i 1))))
                             (list (nth i 3) (psql--human (psql--num (nth i 0)))
                                   (if (and (= scans 0) (equal? (nth i 2) ""))
                                       (list "unused" "psql-warn")
                                       (nth i 1))
                                   (list (psql--bar scans mx 12) "psql-bar")
                                   (nth i 4))))
                         #f #f)))
  (section-close (psql--tsec s t "indexes"))
  (section-line "" #f))

(define (psql--emit-constraints s t cons-)
  (section-open (psql--tsec s t "constraints")
                (string-append "Constraints (" (number->string (length cons-)) ")")
                "psql-section")
  (if (null? cons-)
      (section-line "    (none)" "psql-dim")
      (psql--emit-rows (list "TYPE" "NAME" "DEFINITION")
                       cons-
                       (lambda (c) (list (psql--contype (nth c 0)) (nth c 1) (nth c 4)))
                       ;; a foreign key row opens the table it references
                       (lambda (c) (unless (equal? (nth c 3) "")
                                     (psql--record "table" (nth c 2) (nth c 3))))
                       #f))
  (section-close (psql--tsec s t "constraints"))
  (section-line "" #f))

(define (psql--emit-referenced-by s t refs)
  (section-open (psql--tsec s t "refby")
                (string-append "Referenced by (" (number->string (length refs)) ")")
                "psql-section")
  (if (null? refs)
      (section-line "    (no foreign keys point here)" "psql-dim")
      (psql--emit-rows (list "TABLE" "CONSTRAINT" "DEFINITION")
                       refs
                       (lambda (r) (list (psql--qual (nth r 0) (nth r 1)) (nth r 2) (nth r 3)))
                       (lambda (r) (psql--record "table" (nth r 0) (nth r 1)))
                       #f))
  (section-close (psql--tsec s t "refby")))

(define (psql--render-table s t)
  (let* ((oid (psql--reloid s t))
         (res (psql--batch (psql--table-specs oid))))
    (when res
      (let ((qs (car res)))
        (if (null? (nth qs 0))
            (message (string-append "psql: no such relation — " s "." t))
            (let* ((o     (car (nth qs 0)))
                   (kind  (psql--nth-or o 0 ""))
                   (buf   (psql--table-buffer s t))
                   (st    (if (null? (nth qs 1)) '() (car (nth qs 1))))
                   (io    (if (null? (nth qs 2)) '() (car (nth qs 2))))
                   (desc  (psql--nth-or o 7 ""))
                   (line  (if (equal? (current-buffer) buf) (buffer-line) 0)))
              (psql--lm-begin! buf)
              (psql--view-set! buf (list "table" s t))
              (section-begin)
              (section-line (string-append (psql--kind kind) ": " s "." t
                                           "   Owner: " (psql--nth-or o 1 "?")
                                           "   ~" (psql--rows-h (psql--num (psql--nth-or o 2 "-1"))) " rows"
                                           "   Total: " (psql--human (psql--num (psql--nth-or o 3 "0"))))
                            "psql-header")
              (unless (equal? desc "") (section-line desc "psql-dim"))
              (psql--emit-hint "^ up to schema · RET follow foreign key · v preview rows · r refresh · s query · q quit")
              (unless (psql--sizeless? kind)
                (section-open (psql--tsec s t "size") "Size" "psql-section")
                (psql--emit-table-size o)
                (section-close (psql--tsec s t "size"))
                (section-line "" #f))
              (unless (null? st)
                (section-open (psql--tsec s t "stats") "Stats" "psql-section")
                (psql--emit-table-stats st io)
                (section-close (psql--tsec s t "stats"))
                (section-line "" #f))
              (psql--emit-columns s t (nth qs 3))
              (psql--emit-indexes s t (nth qs 4))
              (psql--emit-constraints s t (nth qs 5))
              (psql--emit-referenced-by s t (nth qs 6))
              ;; view definition
              (when (member kind (list "v" "m"))
                (section-line "" #f)
                (section-open (psql--tsec s t "viewdef") "Definition" "psql-section")
                (let ((def (psql--raw (string-append "select pg_get_viewdef(" oid ", true)"))))
                  (if (or (not def) (equal? def ""))
                      (section-line "    (unavailable)" "psql-dim")
                      (for-each (lambda (l) (section-line (string-append "    " l) #f))
                                (split-many def "\n"))))
                (section-close (psql--tsec s t "viewdef")))
              (section-render buf "psql-mode")
              (goto-line line)))))))

;; ── entry / navigation commands ───────────────────────────────────────────────
(define-command (psql-dashboard) (psql--with-url psql--render-dashboard))

;; Refresh whatever psql buffer we're in.
(define-command (psql-refresh)
  (let ((v (psql--view (current-buffer))))
    (if (not v)
        (message "psql: not a psql buffer")
        (psql--with-url
          (lambda ()
            (cond ((equal? (car v) "dashboard") (psql--render-dashboard))
                  ((equal? (car v) "schema")    (psql--render-schema (nth v 1)))
                  ((equal? (car v) "table")     (psql--render-table (nth v 1) (nth v 2)))))))))

;; RET / g: drill into the thing at point (schema heading → schema buffer,
;; table row → table buffer). TAB folds instead — magit muscle memory.
(define-command (psql-visit)
  (let ((e (psql--at)))
    (if (not e)
        (message "psql: nothing to open here")
        (psql--with-url
          (lambda ()
            (cond ((equal? (nth e 1) "schema") (psql--render-schema (nth e 2)))
                  ((equal? (nth e 1) "table")  (psql--render-table (nth e 2) (nth e 3)))))))))

;; ^: go up a level (table → its schema, schema → dashboard).
(define-command (psql-up)
  (let ((v (psql--view (current-buffer))))
    (cond ((and v (equal? (car v) "table"))
           (psql--with-url (lambda () (psql--render-schema (nth v 1)))))
          ((and v (equal? (car v) "schema")) (psql--with-url psql--render-dashboard))
          (else (message "psql: already at the top")))))

(define-command (psql-toggle-fold) (section-toggle-at-point))

;; v: the first rows of the table at point (or of this table buffer), as a grid.
(define (psql--ident x) (string-append "\"" (string-join (split-many x "\"") "\"\"") "\""))
(define (psql--preview-rows) (psql--option-num "psql-preview-rows" 200))
(define-command (psql-preview)
  (let* ((e (psql--at))
         (v (psql--view (current-buffer)))
         (target (cond ((and e (equal? (nth e 1) "table")) (list (nth e 2) (nth e 3)))
                       ((and v (equal? (car v) "table")) (list (nth v 1) (nth v 2)))
                       (else #f))))
    (if (not target)
        (message "psql: no table here to preview")
        (psql--with-url
          (lambda ()
            (psql--run-sql (string-append "select * from " (psql--ident (car target)) "."
                                          (psql--ident (cadr target)) " limit "
                                          (number->string (psql--preview-rows)) ";")))))))

;; ── auto-refresh ──────────────────────────────────────────────────────────────
;; One self-rearming timer (the k8s-dashboard pattern). A tick re-renders the
;; dashboard only while it's the buffer in front — renders are synchronous, so
;; a background tick would steal focus — and the chain stops once auto-refresh
;; is off or the dashboard is gone. Interval: the "psql-auto-refresh" option,
;; in seconds (default 10).
(define (psql--auto-ms) (* 1000 (max 2 (psql--option-num "psql-auto-refresh" 10))))
(define (psql--arm-timer)
  (when (not (psql--st 'timer-armed))
    (psql--st! 'timer-armed #t)
    (run-with-timer (psql--auto-ms) "psql--tick")))
(define-command (psql--tick)
  (psql--st! 'timer-armed #f)
  (when (and (psql--st 'auto) (member "*psql-dashboard*" (buffer-names)))
    (when (and (equal? (current-buffer) "*psql-dashboard*") (not (psql--url-pending?)))
      (psql--st! 'quiet #t)
      (psql--render-dashboard)
      (psql--st! 'quiet #f))
    (psql--arm-timer)))
(define-command (psql-toggle-auto)
  (psql--st! 'auto (not (psql--st 'auto)))
  (if (psql--st 'auto)
      (begin (message (string-append "psql: auto-refresh on ("
                                     (number->string (quotient (psql--auto-ms) 1000)) "s)"))
             (psql--arm-timer))
      (message "psql: auto-refresh off"))
  (when (equal? (current-buffer) "*psql-dashboard*") (psql-refresh)))

(define (psql--apply-url u)
  (set-option "psql-url" (trim-end (trim-start u)))
  (psql--st! 'cat-state "")   ; new database → stale completion catalog
  (psql--st! 'samples '())    ; …and its counters aren't comparable
  (message (string-append "psql: url set to " (psql--display-url)))
  (when (psql--view (current-buffer)) (psql-refresh)))
(define-command (psql-set-url . rest)
  (if (null? rest)
      (read-string "psql URL: " psql--apply-url)
      (psql--apply-url (car rest))))

;; ── copy to clipboard ─────────────────────────────────────────────────────────
;; vim/helix yank can't reach these special read-only buffers (only motion is
;; overlaid — same constraint as magit / macros-k8s), so explicit copy commands.
(define (psql--current-line-text)
  (psql--nth-or (split-many (buffer-string) "\n") (buffer-line) ""))
(define-command (psql-copy-line)
  (let ((s (psql--current-line-text)))
    (clipboard-set s)
    (message (string-append "Copied line: " (trim-start s)))))
(define-command (psql-copy-buffer)
  (clipboard-set (buffer-string))
  (message "psql: copied whole buffer to clipboard"))
;; Y in a dashboard buffer: the qualified name at point (fallback: the line).
(define-command (psql-copy)
  (let ((e (psql--at)))
    (cond ((and e (equal? (nth e 1) "table"))
           (clipboard-set (string-append (nth e 2) "." (nth e 3)))
           (message (string-append "Copied " (nth e 2) "." (nth e 3))))
          ((and e (equal? (nth e 1) "schema"))
           (clipboard-set (nth e 2))
           (message (string-append "Copied " (nth e 2))))
          (else (psql-copy-line)))))

;; ── the query pane ────────────────────────────────────────────────────────────
;; `s` (or M-x psql-query) opens *psql-query* in a half-height pane below, in
;; real sql-mode (tree-sitter highlighting, every editing keymap). C-c C-c runs
;; the buffer's SQL asynchronously against the configured URL; results land in
;; *psql-results* (psql's own aligned output + \timing). C-g cancels a running
;; query, C-c C-k closes the pane.
(define (psql--tmpdir)
  (let ((t (getenv "TMPDIR")))
    (cond ((equal? t "") "/tmp")
          ((ends-with? t "/") (substring t 0 (- (string-length t) 1)))
          (else t))))
(define (psql--query-file)
  (string-append (psql--tmpdir) "/macros-psql/query.sql"))
(define (psql--status-file)
  (string-append (psql--tmpdir) "/macros-psql/status"))

;; Results come from psql UNALIGNED (-A) and are aligned by psql--format-results
;; below, clamping each cell. psql's own aligned format is unusable here: it
;; pads every row and the separator rule to the WIDEST cell, so `select *` over
;; ten 2 MB rows (embeddings, blobs, big json) explodes into GIGABYTES of
;; spaces — which reads as the editor hanging.
;;
;; Two caps guard a runaway result:
;;   * "psql-max-rows" (default 2000 output lines) — hit → the run is auto-
;;     cancelled (killing psql cancels the server query too), what arrived is
;;     shown, and the buffer is labeled truncated.
;;   * "psql-max-output" (default 50 MB raw stream, via `head -c`) — the
;;     backstop that stops a single monster line from ballooning the editor.
(define (psql--option-num key default)
  (let* ((v (get-option key))
         (n (if (string? v) (string->number v) #f)))
    (if n n default)))
(define (psql--max-output) (psql--option-num "psql-max-output" 50000000))
(define (psql--max-rows)   (psql--option-num "psql-max-rows" 2000))

(define-command (psql-query)
  (let ((w (get-buffer-window "*psql-query*")))
    (if (>= w 0)
        (select-window w)             ; already visible — just focus it
        (begin
          (split-window-below)        ; half-height pane across the bottom
          (other-window)
          (if (member "*psql-query*" (buffer-names))
              (switch-to-buffer "*psql-query*")
              (begin
                (append-to-buffer "*psql-query*" "")
                (set-major-mode "sql")))))
    (message "SQL — C-c C-c runs the buffer · C-g cancels a running query · C-c C-k closes")))

;; C-c C-c in ANY sql-mode buffer: run the whole buffer's SQL. Async via
;; lib-async so a slow query never freezes the editor; `2>&1` interleaves
;; errors/notices with the output in statement order.
(define-command (psql-run-buffer)
  (let ((sql (buffer-string)))
    (if (psql--blank? sql)
        (message "psql: buffer is empty")
        (psql--with-url (lambda () (psql--run-sql sql))))))

;; Run `sql` asynchronously; results land in a grid (psql--run-exit).
(define (psql--run-sql sql)
  (cond
   ((async-lane-live? "psql")
    (message "psql: a query is already running — C-g cancels it"))
   (else
    (let ((file (psql--query-file))
          (status (psql--status-file))
          (u (psql--url)))
      (write-file file (string-append "\\timing on\n" sql "\n"))
      (psql--st! 'async-out '())
      (psql--st! 'async-n 0)
      (psql--st! 'capped #f)
      ;; -A = unaligned output (headers + footers kept) — the display table is
      ;; built by psql--format-results, with per-cell clamping. FETCH_COUNT
      ;; streams results in batches so the caps can cut a runaway result off
      ;; early. psql's own exit code is smuggled out through a status file —
      ;; the pipeline's code is head's, which is always 0.
      (async-lane-run "psql" "/bin/sh"
        (list "-c" (string-append
                    "{ " (psql--sh-quote (psql--command)) " "
                    (if (equal? u "") "" (string-append "-d " (psql--sh-quote u) " "))
                    "-v FETCH_COUNT=100 -X -q -A"
                    " -P recordsep=" psql--RS " -P fieldsep=" psql--FS
                    " -P pager=off -f " (psql--sh-quote file)
                    " 2>&1; echo $? > " (psql--sh-quote status)
                    "; } | head -c " (number->string (psql--max-output))
                    "; exit \"$(cat " (psql--sh-quote status) ")\""))
        'psql--run-output 'psql--run-exit)
      (message "psql: running… (C-g in the query buffer cancels)")))))

;; Accumulate as a reversed LIST and join once on exit — appending each line to
;; one growing string is quadratic and crawls on megabyte outputs. Past the row
;; cap the run is auto-cancelled: killing psql drops the connection, which
;; cancels the query server-side too.
(define (psql--run-output line)
  (let ((n (+ 1 (psql--st 'async-n))))
    (psql--st! 'async-n n)
    (cond ((<= n (psql--max-rows))
           (psql--st! 'async-out (cons line (psql--st 'async-out))))
          ((not (psql--st 'capped))
           (psql--st! 'capped #t)
           (async-lane-cancel "psql")))))

;; ── results formatting ────────────────────────────────────────────────────────
;; Queries run with SENTINEL separators (`-P recordsep/fieldsep`), so record
;; and cell boundaries are exact: a value containing a newline or a `|` can't
;; break its row — EVERY row lands in the table. Each result set becomes an
;; ORG-MODE table — `| cell | cell |` rows, a `|---+---|` rule under the
;; header — cells clamped to 80 chars (one fat embedding costs 80 chars, not
;; megabytes of padding) and embedded newlines shown as ⏎. Footers, timing,
;; and errors pass through between tables. Produced as (text face) pairs; the
;; babel path joins just the texts (the rows ARE org table syntax, so a
;; #+RESULTS: block holds a real org table).
(define psql--RS "@@RS@@")
(define psql--FS "@@FS@@")
(define psql--cell-width 80)
(define (psql--clamp-cell s)
  (if (> (string-length s) psql--cell-width)
      (string-append (substring s 0 psql--cell-width) "…")
      s))
(define (psql--flatten-nl s)
  (if (string-contains? s "\n") (string-join (split-many s "\n") "⏎") s))
(define (psql--record-cells rec)
  (map (lambda (c) (psql--clamp-cell (psql--flatten-nl c)))
       (split-many rec psql--FS)))

;; One org table row: `| c1 | c2 |`, every cell padded to its column width.
(define (psql--fmt-cells cells ws)
  (let loop ((cs cells) (ws ws) (acc "|"))
    (if (null? cs)
        acc
        (loop (cdr cs) (if (null? ws) '() (cdr ws))
              (string-append acc " "
                             (pad-right (car cs) (if (null? ws) 0 (car ws)))
                             " |")))))
;; The org rule under the header: `|----+----|`.
(define (psql--rule ws)
  (let loop ((ws ws) (acc "|"))
    (if (null? ws)
        acc
        (loop (cdr ws)
              (string-append acc (string-repeat "-" (+ (car ws) 2))
                             (if (null? (cdr ws)) "|" "+"))))))

;; One result set (header record first) → org-table (text face) pairs.
(define (psql--format-block records)
  (let* ((rows (map psql--record-cells records))
         (ws (psql--widths rows))
         (formatted (map (lambda (r) (psql--fmt-cells r ws)) rows)))
    (if (< (length formatted) 2)
        (map (lambda (l) (list l "psql-header")) formatted)
        (cons (list (car formatted) "psql-header")
              (cons (list (psql--rule ws) "psql-dim")
                    (map (lambda (l) (list l #f)) (cdr formatted)))))))

;; A line that is psql chatter rather than data: footers, timing, errors.
(define (psql--meta-line? l)
  (or (equal? (trim-end l) "")
      (starts-with? l "(") (starts-with? l "Time:") (starts-with? l "Timing")
      (starts-with? l "ERROR") (starts-with? l "FATAL") (starts-with? l "NOTICE")
      (starts-with? l "WARNING") (starts-with? l "DETAIL:") (starts-with? l "HINT:")
      (starts-with? l "CONTEXT:") (starts-with? l "LINE ") (starts-with? l "psql:")
      (starts-with? (trim-start l) "^")))
(define (psql--result-line-face line)
  (cond ((or (starts-with? line "ERROR") (starts-with? line "FATAL")
             (starts-with? line "psql:")) "psql-err")
        (else "psql-dim")))

;; Walk the raw stream into an ordered list of items: ("set" records) per
;; result set (its header record first), ("meta" line) for psql chatter. Split
;; on the record sentinel; a chunk whose first line is data extends the current
;; result set (embedded newlines and all); a chunk opening with meta lines ends
;; the set — the metas pass through and any remainder line is the NEXT set's
;; header.
(define (psql--result-items raw)
  (let loop ((chunks (split-many raw psql--RS)) (set '()) (acc '()))
    (define (flush acc)
      (if (null? set) acc (cons (list "set" (reverse set)) acc)))
    (if (null? chunks)
        (reverse (flush acc))
        (let ((ls (split-many (car chunks) "\n")))
          (if (not (psql--meta-line? (car ls)))
              (loop (cdr chunks) (cons (car chunks) set) acc)
              (let walk ((ls ls) (acc (flush acc)))
                (cond
                 ((null? ls) (loop (cdr chunks) '() acc))
                 ((psql--meta-line? (car ls))
                  (walk (cdr ls)
                        (if (equal? (trim-end (car ls)) "")
                            acc
                            (cons (list "meta" (car ls)) acc))))
                 (else
                  ;; remainder — the next result set's header record
                  (loop (cdr chunks) (list (string-join ls "\n")) acc)))))))))

;; Org-table (text face) lines: each set formatted, a blank line before every
;; set after the first, metas faced in between.
(define (psql--faced-lines raw)
  (let loop ((items (psql--result-items raw)) (acc '()))
    (cond ((null? items) (reverse acc))
          ((equal? (car (car items)) "set")
           (loop (cdr items)
                 (append (reverse (psql--format-block (cadr (car items))))
                         (if (null? acc) acc (cons (list "" #f) acc)))))
          (else
           (let ((l (cadr (car items))))
             (loop (cdr items) (cons (list l (psql--result-line-face l)) acc)))))))

;; Plain-text variant (the org-babel results path).
(define (psql--format-results raw)
  (string-join (map car (psql--faced-lines raw)) "\n"))

;; Results open as a REAL org file buffer (a temp results.org), not a special
;; render-buffer — so the tables fontify and behave as genuine org tables, and
;; every keymap works as in any file (the k8s-yaml pattern). Re-running a
;; query re-reads the file in place.
(define (psql--results-file)
  (string-append (psql--tmpdir) "/macros-psql/results.org"))

(define (psql--run-exit code)
  (let ((user-cancelled (and (async-lane-finish "psql") (not (psql--st 'capped)))))
    (cond
     (user-cancelled (message "psql: query cancelled"))
     ((psql--not-found? code) (message (psql--not-found-msg)))
     (else
        (let* ((raw (trim-end (string-join (reverse (psql--st 'async-out)) "\n")))
               ;; 141 = SIGPIPE = head hit the raw-stream backstop
               (note (cond ((psql--st 'capped)
                            "truncated at psql-max-rows lines (auto-cancelled)")
                           ((equal? code "141")
                            "truncated at psql-max-output bytes")
                           (else "")))
               (items (if (psql--blank? raw) '() (psql--result-items raw)))
               (sets (map cadr (filter (lambda (i) (equal? (car i) "set")) items)))
               (metas (map cadr (filter (lambda (i) (equal? (car i) "meta")) items)))
               (errored (pair? (filter (lambda (l) (equal? (psql--result-line-face l) "psql-err"))
                                       metas))))
          ;; Data with no errors → a grid. Errors, or statements with no result
          ;; set (DDL, SET, …), → the org results file, where the messages read.
          (if (and (pair? sets) (not errored) (equal? (psql--results-view) "grid"))
              (psql--show-grid sets metas note)
              (psql--show-org raw code note)))))))

;; "grid" (default) or "org" — the "psql-results-view" option.
(define (psql--results-view)
  (let ((v (get-option "psql-results-view")))
    (if (and (string? v) (equal? v "org")) "org" "grid")))

;; open-file's own "Visiting …" lands after anything said in the same command,
;; so the summary is said a beat later.
(define (psql--say-later text)
  (psql--st! 'pending-msg text)
  (run-with-timer 50 "psql--say-pending"))
(define (psql--say-pending) (message (psql--st 'pending-msg)))

(define (psql--show-org raw code note)
  (let ((out (if (psql--blank? raw) "(no output)" (psql--format-results raw))))
    (write-file (psql--results-file)
                (string-append out (if (equal? note "") "" (string-append "\n\n… " note " …")) "\n"))
    ;; Show results in the OTHER window, so the query stays visible below.
    (when (equal? (current-buffer) "*psql-query*") (other-window))
    (kill-buffer-named "results.org")   ; drop a stale view so find-file re-reads
    (open-file (psql--results-file))
    (psql--say-later (cond ((not (equal? note "")) (string-append "psql: done — " note ", see results.org"))
                   ((equal? code "0") "psql: done — see results.org")
                   (else "psql: query failed — see results.org")))))

;; ── results as a grid ─────────────────────────────────────────────────────────
;; Each result set becomes a CSV, which macros opens as a grid (sort, filter,
;; resize, copy, formulas). The LAST set is shown — with several statements
;; that's usually the one you care about; earlier sets sit next to it as
;; psql-result-1.csv, psql-result-2.csv, … Cells are the full values (no
;; clamping: the grid truncates for display, not the data).
(define (psql--grid-file i)
  (string-append (psql--tmpdir) "/macros-psql/psql-result"
                 (if (= i 0) "" (string-append "-" (number->string i))) ".csv"))
(define (psql--csv-cell c)
  (if (or (string-contains? c ",") (string-contains? c "\"")
          (string-contains? c "\n") (string-contains? c "\r"))
      (string-append "\"" (string-join (split-many c "\"") "\"\"") "\"")
      c))
(define (psql--csv records)
  (string-join (map (lambda (rec) (string-join (map psql--csv-cell (split-many rec psql--FS)) ","))
                    records)
               "\n"))

(define (psql--show-grid sets metas note)
  (let loop ((ss sets) (i 1))
    (when (pair? ss)
      (write-file (psql--grid-file (if (null? (cdr ss)) 0 i))
                  (string-append (psql--csv (car ss)) "\n"))
      (loop (cdr ss) (+ i 1))))
  (when (equal? (current-buffer) "*psql-query*") (other-window))
  (kill-buffer-named "psql-result.csv")   ; drop a stale grid so it re-reads
  (open-file (psql--grid-file 0))
  (let* ((rows (filter (lambda (l) (and (starts-with? l "(") (string-contains? l "row"))) metas))
         (times (filter (lambda (l) (starts-with? l "Time:")) metas))
         (parts (append (if (null? rows) '() (list (car (reverse rows))))
                        (if (null? times) '() (list (car (reverse times))))
                        (if (> (length sets) 1)
                            (list (string-append (number->string (length sets))
                                                 " result sets — showing the last; earlier ones are psql-result-N.csv"))
                            '())
                        (if (equal? note "") '() (list note)))))
    (psql--say-later (string-append "psql: " (if (null? parts) "done" (string-join parts " · "))))))

;; Header row + frozen header for our result grids.
(define (psql--grid-load name)
  (when (starts-with? name "psql-result")
    (grid-set-header #t)
    (grid-freeze-rows 1)))
(remove-hook "grid-load-hook" "psql--grid-load")
(add-hook "grid-load-hook" "psql--grid-load")

;; C-g in a sql buffer: cancel a live query, else the ordinary keyboard-quit.
(define-command (psql-query-cancel) (async-lane-quit "psql"))
;; C-c C-k from the query pane: kill the buffer and collapse the pane.
(define-command (psql-query-close)
  (let ((in-pane (equal? (current-buffer) "*psql-query*")))
    (kill-buffer-named "*psql-query*")
    (when in-pane (delete-window))
    (message "psql: query buffer closed")))

;; ── org-babel (#+BEGIN_SRC psql / sql) ───────────────────────────────────────
;; C-c C-c (org-babel-execute) inside a `psql` or `sql` src block runs its body
;; against the configured URL and writes the aligned, cell-clamped table into
;; the #+RESULTS block. Registered through org.scm's executor registry, so this
;; is inert when org-mode support is absent (older builds). Babel is
;; synchronous by design (the result goes straight into the buffer), so output
;; is capped tight: keep org blocks to queries, not dumps.
(define psql--babel-max-bytes 1000000)

(define (psql--babel-run body)
  (if (psql--url-pending?)
      "psql-url is in authinfo.gpg, which is locked — run M-x psql-dashboard (or secrets-unlock) first"
      (psql--babel-run-now body)))
(define (psql--babel-run-now body)
  (let* ((u (psql--url))
         (r (call-process-full "/bin/sh"
              (list "-c" (string-append
                          ;; the pipeline's code is head's — check up front so a
                          ;; missing binary still surfaces as 127
                          "command -v " (psql--sh-quote (psql--command)) " >/dev/null || exit 127; "
                          (psql--sh-quote (psql--command)) " "
                          (if (equal? u "") "" (string-append "-d " (psql--sh-quote u) " "))
                          "-v FETCH_COUNT=100 -X -q -A"
                          " -P recordsep=" psql--RS " -P fieldsep=" psql--FS
                          " -P pager=off -f - 2>&1"
                          " | head -c " (number->string psql--babel-max-bytes)))
              (string-append body "\n")))
         (out (if (psql--not-found? (car r))
                  (psql--not-found-msg)
                  (trim-end (psql--format-results (trim-end (nth r 1))))))
         (rows (split-many out "\n"))
         (capped (> (length rows) (psql--max-rows)))
         (shown (if capped
                    (string-join (psql--take rows (psql--max-rows)) "\n")
                    out)))
    (string-append (if (equal? shown "") "(no output)" shown)
                   (if capped "\n… truncated at psql-max-rows lines …" ""))))

(define (psql--take lst n)
  (if (or (= n 0) (null? lst)) '() (cons (car lst) (psql--take (cdr lst) (- n 1)))))

;; Older editor builds have no registry. Steel rejects a whole file over one
;; unknown identifier, so the probe uses function-list and the registration
;; goes through eval-string — the name only resolves once the probe passed.
(when (member "org-babel-register-language" (function-list))
  (eval-string "(org-babel-register-language \"psql\" psql--babel-run)")
  (eval-string "(org-babel-register-language \"sql\" psql--babel-run)"))

;; ── SQL completion (CAPF) ─────────────────────────────────────────────────────
;; Completes schema / table / column names from the connected database's own
;; catalog — plus common SQL keywords — in the *psql-query* pane and any .sql
;; buffer. Registered on the editor's completion-at-point chain (M-i), reusing
;; core completion.scm's capf helpers. Context-aware:
;;   * after `schema.`          → that schema's tables
;;   * after `table.`           → that table's columns
;;   * after FROM/JOIN/INTO/…   → tables and schemas
;;   * anywhere else            → keywords + tables (+ columns once you've typed
;;                                a character — the full column list is noisy)
;; The catalog is ONE pg_attribute query, cached; every dashboard render
;; refreshes it, `M-x psql-catalog-refresh` forces it, and changing the URL
;; invalidates it. A failed fetch is remembered so completion doesn't hammer a
;; dead connection on every keystroke.

(define psql--sql-keywords
  (list "select" "from" "where" "and" "or" "not" "in" "as" "join" "left" "right"
        "inner" "outer" "full" "cross" "on" "group" "by" "order" "limit" "offset"
        "having" "distinct" "insert" "into" "values" "update" "set" "delete"
        "create" "table" "index" "view" "drop" "alter" "add" "column" "primary"
        "key" "foreign" "references" "unique" "null" "default" "case" "when"
        "then" "else" "end" "union" "all" "exists" "between" "like" "ilike" "is"
        "asc" "desc" "count" "sum" "avg" "min" "max" "coalesce" "cast" "with"
        "returning" "explain" "analyze" "vacuum" "begin" "commit" "rollback"))

;; Like psql--query but silent on failure (a completion popup must never throw
;; an error buffer in your face) — returns #f instead.
(define (psql--query-quiet sql ncols)
  (let ((r (psql--run-full (append (psql--conn)
                                   (list "-X" "-q" "-A" "-t" "-P" "pager=off" "-c" sql)))))
    (if (equal? (car r) "0")
        (map (lambda (ln) (psql--fields-n ln ncols)) (psql--lines (nth r 1)))
        #f)))

(define psql--catalog-sql
  (string-append
   "select n.nspname, c.relname, a.attname"
   " from pg_attribute a"
   " join pg_class c on c.oid = a.attrelid"
   " join pg_namespace n on n.oid = c.relnamespace"
   " where c.relkind in ('r','p','m','v','f') and a.attnum > 0 and not a.attisdropped"
   " and left(n.nspname,3) <> 'pg_' and n.nspname <> 'information_schema'"
   " order by n.nspname, c.relname, a.attnum"))

;; Rows arrive grouped by (schema, table), so one linear pass builds the whole
;; catalog: schema list, (schema table) list, and a columns alist keyed by BOTH
;; the bare table name and "schema.table" (bare key: first schema wins).
(define (psql--catalog-build! rows)
  (let loop ((rs rows) (schemas '()) (tables '()) (cols '())
             (cur-s "") (cur-t "") (cur-cols '()))
    (define (flush cols)
      (if (equal? cur-t "")
          cols
          (let ((cl (reverse cur-cols)))
            (cons (cons (string-append cur-s "." cur-t) cl)
                  (if (alist-ref cols cur-t) cols (cons (cons cur-t cl) cols))))))
    (if (null? rs)
        (begin
          (psql--st! 'cat-schemas (reverse schemas))
          (psql--st! 'cat-tables (reverse tables))
          (psql--st! 'cat-cols (flush cols))
          (psql--st! 'cat-state "ok"))
        (let* ((r (car rs))
               (s (psql--nth-or r 0 "")) (t (psql--nth-or r 1 ""))
               (c (psql--nth-or r 2 "")))
          (if (and (equal? s cur-s) (equal? t cur-t))
              (loop (cdr rs) schemas tables cols cur-s cur-t (cons c cur-cols))
              (loop (cdr rs)
                    (if (member s schemas) schemas (cons s schemas))
                    (cons (list s t) tables)
                    (flush cols)
                    s t (list c)))))))

(define (psql--catalog-refresh!)
  (let ((rows (psql--query-quiet psql--catalog-sql 3)))
    (if rows
        (psql--catalog-build! rows)
        (psql--st! 'cat-state "failed"))))
(define (psql--catalog-ensure!)
  ;; a still-locked URL would hit the PG* defaults and cache "failed"
  (when (and (equal? (psql--st 'cat-state) "") (not (psql--url-pending?)))
    (psql--catalog-refresh!)))

(define-command (psql-catalog-refresh)
  (psql--with-url
    (lambda ()
      (psql--catalog-refresh!)
      (message (if (equal? (psql--st 'cat-state) "ok")
                   (string-append "psql: catalog cached ("
                                  (number->string (length (psql--st 'cat-tables))) " relations)")
                   "psql: catalog fetch failed — check psql-url")))))

;; Only complete in SQL buffers: the query pane, or any real .sql file.
(define (psql--sql-buffer?)
  (or (equal? (current-buffer) "*psql-query*")
      (let ((f (buffer-file-name)))
        (and (string? f) (ends-with? f ".sql")))))

(define (psql--filter-cands low cands)
  (filter (lambda (c) (starts-with? (string-downcase (car c)) low)) cands))
(define (psql--table-cands)
  (append
   (map (lambda (st) (list (nth st 1) (car st))) (psql--st 'cat-tables))
   (map (lambda (st) (list (string-append (car st) "." (nth st 1)) "table"))
        (psql--st 'cat-tables))
   (map (lambda (s) (list s "schema")) (psql--st 'cat-schemas))))
(define (psql--column-cands)
  (let loop ((tabs (psql--st 'cat-tables)) (acc '()))
    (if (null? tabs)
        (reverse acc)
        (let* ((s (car (car tabs))) (t (nth (car tabs) 1))
               (cl (alist-ref (psql--st 'cat-cols) (string-append s "." t))))
          (loop (cdr tabs)
                (let inner ((cs (if cl cl '())) (a acc))
                  (if (null? cs) a (inner (cdr cs) (cons (list (car cs) t) a)))))))))
;; Keywords follow the case you're typing: SEL… completes SELECT, sel… select.
(define (psql--keyword-cands sym)
  (let ((upper (and (> (string-length sym) 0)
                    (not (equal? (substring sym 0 1)
                                 (string-downcase (substring sym 0 1)))))))
    (map (lambda (k) (list (if upper (string-upcase k) k) "keyword"))
         psql--sql-keywords)))

;; Is the token before the current symbol a keyword that introduces a table
;; name? (Scans the text before point, minus the half-typed symbol.)
(define (psql--table-context? before)
  (member (string-downcase (capf-symbol-prefix (trim-end before)))
          (list "from" "join" "into" "update" "table")))

(define (psql--sql-candidates before sym)
  (let ((low (string-downcase sym)))
    (cond
     ;; `qualifier.` — a schema's tables, or a table's columns
     ((ends-with? before ".")
      (let ((q (capf-symbol-prefix (substring before 0 (- (string-length before) 1)))))
        (cond
         ((member q (psql--st 'cat-schemas))
          (psql--filter-cands low
            (map (lambda (st) (list (nth st 1) "table"))
                 (filter (lambda (st) (equal? (car st) q)) (psql--st 'cat-tables)))))
         (else
          (let ((cl (alist-ref (psql--st 'cat-cols) q)))
            (if cl
                (psql--filter-cands low (map (lambda (c) (list c q)) cl))
                '()))))))
     ((psql--table-context? before)
      (psql--filter-cands low (psql--table-cands)))
     (else
      (psql--filter-cands low
        (append (psql--keyword-cands sym)
                (psql--table-cands)
                ;; the full column list only once something's been typed
                (if (> (string-length sym) 0) (psql--column-cands) '())))))))

(define (psql-sql-capf prefix)
  (if (not (psql--sql-buffer?))
      '()
      (begin
        (psql--catalog-ensure!)
        (if (not (equal? (psql--st 'cat-state) "ok"))
            '()
            (let* ((p (point))
                   (text (buffer-substring (max 0 (- p 1024)) p))
                   (sym (capf-symbol-prefix text))
                   (before (substring text 0 (- (string-length text) (string-length sym))))
                   (cands (psql--sql-candidates before sym)))
              (if (null? cands) '() (list (- p (string-length sym)) p cands)))))))
(add-completion-at-point-function "psql-sql-capf")

;; ── dispatch popup (?) ────────────────────────────────────────────────────────
(define-command (psql-dispatch)
  (let ((e (psql--at)))
    (cond
     ((and e (equal? (nth e 1) "table"))
      (transient (string-append "Table: " (nth e 2) "." (nth e 3))
        (list (list "Inspect"
                    (list "i" "Table info"       'psql-visit)
                    (list "v" "Preview rows"     'psql-preview)
                    (list "shift-y" "Copy name"  'psql-copy))
              (list "View"
                    (list "s" "SQL query"        'psql-query)
                    (list "r" "Refresh"          'psql-refresh)
                    (list "q" "Close"            'transient-quit)))))
     ((and e (equal? (nth e 1) "schema"))
      (transient (string-append "Schema: " (nth e 2))
        (list (list "Inspect"
                    (list "i" "Schema info"      'psql-visit)
                    (list "f" "Fold/unfold"      'psql-toggle-fold)
                    (list "shift-y" "Copy name"  'psql-copy))
              (list "View"
                    (list "s" "SQL query"        'psql-query)
                    (list "r" "Refresh"          'psql-refresh)
                    (list "q" "Close"            'transient-quit)))))
     (else
      (transient "PostgreSQL"
        (list (list "View"
                    (list "r" "Refresh"          'psql-refresh)
                    (list "a" "Auto-refresh"     'psql-toggle-auto)
                    (list "s" "SQL query"        'psql-query)
                    (list "v" "Preview rows"     'psql-preview)
                    (list "shift-u" "Set URL"    'psql-set-url)
                    (list "^" "Up a level"       'psql-up)
                    (list "q" "Close"            'transient-quit))))))))

;; ── keymaps ───────────────────────────────────────────────────────────────────
;; Dashboard / schema / table buffers (list views — no line-number gutter).
(set-option "line-numbers:psql-mode" "false")
(define-key "psql-mode" "r" 'psql-refresh)
(define-key "psql-mode" "tab" 'psql-toggle-fold)
(define-key "psql-mode" "enter" 'psql-visit)
(define-key "psql-mode" "g" 'psql-visit)
(define-key "psql-mode" "s" 'psql-query)
(define-key "psql-mode" "v" 'psql-preview)
(define-key "psql-mode" "a" 'psql-toggle-auto)
(define-key "psql-mode" "^" 'psql-up)
(define-key "psql-mode" "shift-u" 'psql-set-url)
(define-key "psql-mode" "shift-y" 'psql-copy)
(define-key "psql-mode" "?" 'psql-dispatch)
(define-key "psql-mode" "n" 'next-line)
(define-key "psql-mode" "p" 'previous-line)
(define-key "psql-mode" "q" 'kill-buffer)

;; Results / error buffers: read-only scroll + copy.
(set-option "line-numbers:psql-result-mode" "false")
(define-key "psql-result-mode" "y y" 'psql-copy-line)
(define-key "psql-result-mode" "shift-y" 'psql-copy-buffer)
(define-key "psql-result-mode" "n" 'next-line)
(define-key "psql-result-mode" "p" 'previous-line)
(define-key "psql-result-mode" "q" 'kill-buffer)

;; sql-mode: run / cancel / close. These land in the "sql" major-mode keymap, so
;; C-c C-c runs the buffer's SQL from any .sql file too (against `psql-url`) —
;; the Emacs sql-mode habit. C-g falls through to keyboard-quit when no query is
;; running, so it stays safe as a global-quit key in sql buffers.
(define-key "sql" "ctrl-c ctrl-c" 'psql-run-buffer)
(define-key "sql" "ctrl-c ctrl-k" 'psql-query-close)
;; Plain C-g is resolved by the evil layer before major-mode keymaps, so the
;; C-c C-g chord is the binding that works everywhere; C-g still cancels under
;; plain Emacs bindings.
(define-key "sql" "ctrl-g" 'psql-query-cancel)
(define-key "sql" "ctrl-c ctrl-g" 'psql-query-cancel)

;; ── evil / helix motion overlays ──────────────────────────────────────────────
;; Special buffers drive their own keymaps; the editor consults an
;; `evil-normal:<mode>` / `helix-normal:<mode>` overlay first, so j/k etc. work
;; without touching the global modal maps. Inert under plain Emacs bindings.

;; Dashboard buffers: motion only, so the letter action keys stay free.
(define (psql--bind-status-motion km)
  (define-key km "j" 'next-line)
  (define-key km "k" 'previous-line)
  (define-key km "shift-g" 'evil-goto-last-line)
  (define-key km "ctrl-d" 'evil-scroll-down)
  (define-key km "ctrl-u" 'evil-scroll-up))
(psql--bind-status-motion "evil-normal:psql-mode")
(psql--bind-status-motion "helix-normal:psql-mode")

;; Results / error buffers: the full read-only motion set.
(define (psql--bind-readonly-motion km)
  (define-key km "j" 'next-line)
  (define-key km "k" 'previous-line)
  (define-key km "h" 'backward-char)
  (define-key km "l" 'forward-char)
  (define-key km "w" 'forward-word-start)
  (define-key km "b" 'backward-word)
  (define-key km "e" 'evil-forward-word-end)
  (define-key km "0" 'move-beginning-of-line)
  (define-key km "$" 'move-end-of-line)
  (define-key km "^" 'evil-first-non-blank)
  (define-key km "g g" 'evil-goto-first-line)
  (define-key km "shift-g" 'evil-goto-last-line)
  (define-key km "ctrl-d" 'evil-scroll-down)
  (define-key km "ctrl-u" 'evil-scroll-up))
(psql--bind-readonly-motion "evil-normal:psql-result-mode")
(psql--bind-readonly-motion "helix-normal:psql-result-mode")
