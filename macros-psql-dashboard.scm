;;; macros-psql-dashboard — a PostgreSQL dashboard for the macros editor, in Steel.
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
;;;   *psql-dashboard*        all schemas, each a foldable section (TAB folds)
;;;                           listing its tables (kind, ~rows, size), plus live
;;;                           activity.
;;;                           RET / g on a schema heading → the schema buffer;
;;;                           RET / g on a table row      → the table buffer.
;;;   *psql-schema:S*         schema info + its tables with size breakdown
;;;                           (total / table / indexes). RET / g drills into a
;;;                           table; ^ goes back up to the dashboard.
;;;   *psql-table:S.T*        columns, indexes, constraints, stats, sizes (and
;;;                           the definition, for views). ^ goes up to the schema.
;;;   *psql-query*            an editable sql-mode buffer in a half-height pane
;;;                           (`s` from any dashboard buffer, or M-x psql-query).
;;;                           C-c C-c runs the buffer's SQL asynchronously;
;;;                           C-g cancels a running query; C-c C-k closes it.
;;;   *psql-results*          the query output (psql's aligned table + timing).
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

;; The connection URL. Either leave the password OUT of it:
;;   (set-option "psql-url" "postgres://user@host:5432/dbname")
;; and it comes from the editor's secrets store (authinfo.gpg, see macros
;; scheme/secrets.scm) — asked for once, offered to save — or keep the WHOLE
;; URL in the store:
;;   (set-option "psql-url" (secret-get "psql-url-1" "alice"))
;; which is asked for (and offered to save) the first time a command needs it.
;; Either way psql gets the password as PGPASSWORD, never in argv: a
;; `user:pass@` URL is split before spawning. Empty / unset = psql's own
;; defaults (PGHOST / ~/.pgpass etc.).
(define (psql--url)
  (let ((v (get-option "psql-url")))
    (if (string? v) v "")))

;; ── faces ─────────────────────────────────────────────────────────────────────
;; User-overridable: redefine any of these in init.scm (re-apply after a
;; load-theme, which wipes the palette).
(set-face "psql-header"  "#66d9ef")   ; the database / connection line
(set-face "psql-section" "#a6e22e")   ; section headings
(set-face "psql-ok"      "#a6e22e")   ; active backends
(set-face "psql-warn"    "#e6db74")   ; idle in transaction, dead tuples
(set-face "psql-err"     "#f92672")   ; errors
(set-face "psql-dim"     "#888888")   ; column headers, hints, empty notes

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
  (let ((u (psql--url))
        (secret (option-secret-label "psql-url")))
    (cond ((psql--url-locked?) (string-append "(secret " secret " — locked)"))
          ((equal? u "") "(PG* environment)")
          (else (psql--redact u)))))

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

;; ── password (secrets store) ──────────────────────────────────────────────────
;; The secrets-store key for a URL: (host user port), or #f when the store
;; isn't involved — no URL (PG* env / ~/.pgpass), a key=value conninfo string,
;; a unix-socket URL with no host, or a URL that already carries a password.
;;   postgres://alice@db.example.com:5432/app → ("db.example.com" "alice" "5432")
(define (psql--url-auth-key u)
  (let* ((rest (cond ((starts-with? u "postgresql://") (substring u 13 (string-length u)))
                     ((starts-with? u "postgres://") (substring u 11 (string-length u)))
                     (else #f))))
    (and rest
         (let* ((authority (car (split-many (car (split-many rest "/")) "?")))
                (at (split-many authority "@"))
                (creds (if (null? (cdr at)) "" (string-join (reverse (cdr (reverse at))) "@")))
                (hostport (car (reverse at))))
           (and (not (string-contains? creds ":"))       ; user:pass@ → used as-is
                (let* ((v6 (starts-with? hostport "["))
                       (parts (if v6
                                  (split-many (substring hostport 1 (string-length hostport)) "]")
                                  (split-many hostport ":")))
                       (host (car parts))
                       (port (cond ((null? (cdr parts)) "")
                                   (v6 (let ((p (cadr parts)))
                                         (if (starts-with? p ":") (substring p 1 (string-length p)) "")))
                                   (else (cadr parts)))))
                  (and (not (equal? host "")) (list host creds port))))))))
(define (psql--auth-key) (psql--url-auth-key (psql--url)))

;; Split a URL's embedded password out: → (url-for-argv password-or-#f).
;;   postgres://alice:p%40ss@db/app → ("postgres://alice@db/app" "p@ss")
;; The password is percent-decoded (as psql itself would); anything that isn't
;; a postgres:// URL with `user:pass@` comes back unchanged with #f.
(define (psql--url-split u)
  (let ((prefix (cond ((starts-with? u "postgresql://") "postgresql://")
                      ((starts-with? u "postgres://") "postgres://")
                      (else #f))))
    (if (not prefix)
        (list u #f)
        (let* ((rest (substring u (string-length prefix) (string-length u)))
               (slash (split-many rest "/"))
               (at (split-many (car slash) "@")))
          (if (null? (cdr at))
              (list u #f)
              (let* ((creds (string-join (reverse (cdr (reverse at))) "@"))
                     (hostport (car (reverse at)))
                     (colon (split-many creds ":")))
                (if (null? (cdr colon))
                    (list u #f)
                    (list (string-append prefix (car colon) "@" hostport
                                         (if (null? (cdr slash))
                                             ""
                                             (string-append "/" (string-join (cdr slash) "/"))))
                          (url-decode (string-join (cdr colon) ":"))))))))))

;; The URL as psql's argv sees it: never with a password in it.
(define (psql--conn-url) (car (psql--url-split (psql--url))))

;; psql-url is a secret reference whose value isn't available yet (store
;; locked / never entered): spawning now would silently hit psql's DEFAULT
;; database, so the plumbing refuses instead and the gated commands prompt.
(define (psql--url-locked?)
  (and (option-secret-label "psql-url") (not (string? (get-option "psql-url")))))

;; Child env for a psql spawn: the URL's own password, else the secrets
;; store's (a synchronous lookup — never prompts), else nothing.
(define (psql--env)
  (let* ((from-url (cadr (psql--url-split (psql--url))))
         (key (psql--auth-key))
         (pw (or from-url (and key (apply secret-lookup key)))))
    (if pw (list (string-append "PGPASSWORD=" pw)) '())))

;; Run `k` once the URL and its password are available (or not needed). Gates
;; every command that talks to the server, so the spawns inside can stay
;; synchronous and just `psql--env`. Prompts only on a store/session miss:
;; first for a secret-reference URL itself, then for a password-less URL's
;; password.
(define (psql--authed k)
  (let ((cancelled (lambda (what) (lambda (_) (message (string-append "psql: cancelled (no " what ")"))))))
    (option-ensure "psql-url"
      (lambda ()
        (let ((key (psql--auth-key)))
          (if (or (not key) (apply secret-lookup key))
              (k)
              (secret-get (car key) (cadr key)
                          (lambda (_)
                            ;; a completion catalog fetched without the password failed
                            (when (equal? (psql--st 'cat-state) "failed") (psql--st! 'cat-state ""))
                            (k))
                          'port (nth key 2)
                          'on-cancel (cancelled "password")))))
      'on-cancel (cancelled "psql-url"))))

;; psql output saying the server rejected (or never got) a password.
(define (psql--auth-failed? text)
  (or (string-contains? text "password authentication failed")
      (string-contains? text "no password supplied")))

;; The stored password was rejected: delete it, so the next command asks again.
;; A password-less URL's own entry goes; for a URL that came from the store
;; WITH its password inside, the URL entry goes (re-enter the whole URL).
(define (psql--password-rejected)
  (let ((key (psql--auth-key)))
    (cond (key
           (apply secret-forget key)
           (message "psql: password rejected — forgotten; run the command again to re-enter it"))
          ((option-secret-forget "psql-url")
           (message "psql: password rejected — the stored psql-url was forgotten; run the command again to re-enter it")))))

;; ── psql plumbing ─────────────────────────────────────────────────────────────
(define (psql--conn)
  (let ((u (psql--conn-url))) (if (equal? u "") '() (list "-d" u))))
(define psql--locked-error
  "psql-url is a secret that isn't available yet — run a psql command (e.g. M-x psql-dashboard) to enter it")
(define (psql--run-full args)
  (if (psql--url-locked?)
      (list "1" "" psql--locked-error)
      (call-process-env (psql--command) args "" (psql--env))))

(define (psql--error stderr)
  (render-buffer "*psql-error*" "psql-result-mode"
                 (if (psql--blank? stderr) "psql failed (no output)" (trim-end stderr)) '())
  (message "psql failed — see *psql-error*")
  (when (psql--auth-failed? stderr) (psql--password-rejected)))

;; Run `sql`, parse unaligned tuples into rows of exactly `ncols` fields.
;; → a list of rows, or #f after surfacing the error (callers abort on #f).
(define (psql--query sql ncols)
  (let ((r (psql--run-full (append (psql--conn)
                                   (list "-X" "-q" "-A" "-t" "-P" "pager=off" "-c" sql)))))
    (if (equal? (car r) "0")
        (map (lambda (ln) (psql--fields-n ln ncols)) (psql--lines (nth r 1)))
        (begin (psql--error (nth r 2)) #f))))
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

;; ── catalog queries ───────────────────────────────────────────────────────────
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
(define psql--activity-sql
  (string-append
   "select a.pid, coalesce(a.usename,''), coalesce(a.state,''),"
   " coalesce(date_trunc('second', now() - a.query_start)::text, ''),"
   " left(regexp_replace(coalesce(a.query,''), '\\s+', ' ', 'g'), 90)"
   " from pg_stat_activity a"
   " where a.datname = current_database() and a.pid <> pg_backend_pid()"
   " order by a.query_start desc nulls last"))

;; ── dashboard rendering ───────────────────────────────────────────────────────
(define (psql--activity-face state)
  (cond ((equal? state "active") "psql-ok")
        ((string-contains? state "idle in transaction") "psql-warn")
        (else "psql-dim")))

(define (psql--emit-hint text)
  (section-line (string-append "  " text) "psql-dim")
  (section-line "" #f))

;; A column-aligned block: header row (dim) + one row per record. `cells-of`
;; maps a record to its display cells; `record-of` (or #f) is called per record
;; to register the row in the line map; `face-of` (or #f) picks a row face.
(define (psql--emit-rows header records cells-of record-of face-of)
  (let* ((cells (map cells-of records))
         (ws (psql--widths (cons header cells))))
    (section-line (string-append "    " (psql--fmt header ws)) "psql-dim")
    (let loop ((rs records) (cs cells))
      (when (not (null? rs))
        (when record-of (record-of (car rs)))
        (section-line (string-append "    " (psql--fmt (car cs) ws))
                      (if face-of (face-of (car rs)) #f))
        (loop (cdr rs) (cdr cs))))))

;; One schema's foldable section in the dashboard. `rows` are parsed records
;; (kind tuples bytes name), already size-sorted by the SQL.
(define (psql--emit-schema s owner rows)
  (let ((total (psql--sum (map (lambda (r) (nth r 2)) rows))))
    (psql--record "schema" s "")
    (section-open (string-append "psql/" s)
                  (string-append s "  (" (number->string (length rows)) " relations · "
                                 (psql--human total) " · " owner ")")
                  "psql-section")
    (if (null? rows)
        (section-line "    (no relations)" "psql-dim")
        (psql--emit-rows
         (list "NAME" "TYPE" "~ROWS" "SIZE")
         rows
         (lambda (r) (list (nth r 3) (psql--kind (nth r 0))
                           (if (psql--sizeless? (nth r 0)) "-" (psql--rows-h (nth r 1)))
                           (if (psql--sizeless? (nth r 0)) "-" (psql--human (nth r 2)))))
         (lambda (r) (psql--record "table" s (nth r 3)))
         #f))
    (section-close (string-append "psql/" s))
    (section-line "" #f)))

(define (psql--emit-activity act)
  (section-open 'psql-activity
                (string-append "Activity (" (number->string (length act)) ")")
                "psql-section")
  (if (null? act)
      (section-line "    (no other backends)" "psql-dim")
      (psql--emit-rows (list "PID" "USER" "STATE" "TIME" "QUERY")
                       act
                       (lambda (a) a)
                       #f
                       (lambda (a) (psql--activity-face (psql--nth-or a 2 "")))))
  (section-close 'psql-activity)
  (section-line "" #f))

(define (psql--render-dashboard)
  (let ((meta (psql--query
               (string-append "select current_database(), current_user,"
                              " current_setting('server_version'),"
                              " pg_size_pretty(pg_database_size(current_database()))") 4)))
    (when meta   ; #f = connection/query failure, already surfaced
      (let* ((m     (if (null? meta) (list "?" "?" "?" "?") (car meta)))
             (conns (psql--query (string-append
                                  "select count(*), count(*) filter (where state = 'active')"
                                  " from pg_stat_activity where datname = current_database()") 2))
             (tabs    (psql--query psql--tables-sql 5))
             (schemas (psql--query psql--schemas-sql 2))
             (act     (psql--query psql--activity-sql 5))
             (line (if (equal? (current-buffer) "*psql-dashboard*") (buffer-line) 0)))
        (when (and conns tabs schemas act)
          (psql--lm-begin! "*psql-dashboard*")
          (psql--view-set! "*psql-dashboard*" (list "dashboard"))
          (section-begin)
          (section-line (string-append "Database: " (psql--nth-or m 0 "?")
                                       "   PostgreSQL " (psql--nth-or m 2 "?")
                                       "   " (psql--display-url))
                        "psql-header")
          (let ((c (if (null? conns) (list "?" "?") (car conns))))
            (section-line (string-append "Size: " (psql--nth-or m 3 "?")
                                         "   User: " (psql--nth-or m 1 "?")
                                         "   Connections: " (psql--nth-or c 0 "?")
                                         " (" (psql--nth-or c 1 "?") " active)")
                          #f))
          (psql--emit-hint (string-append "r refresh · RET/g drill in · TAB fold · "
                                          "s query · U url · Y copy · ? menu · q quit"))
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
           schemas)
          (psql--emit-activity act)
          (section-render "*psql-dashboard*" "psql-mode")
          (goto-line line)
          ;; piggy-back: refresh the SQL completion catalog while we're here
          (psql--catalog-refresh!))))))

;; ── schema buffer ─────────────────────────────────────────────────────────────
(define (psql--schema-buffer s) (string-append "*psql-schema:" s "*"))

(define (psql--render-schema s)
  (let* ((sq (psql--sq s))
         (info (psql--query
                (string-append "select pg_get_userbyid(n.nspowner),"
                               " coalesce(obj_description(n.oid,'pg_namespace'),'')"
                               " from pg_namespace n where n.nspname = '" sq "'") 2))
         (tabs (psql--query
                (string-append
                 "select c.relkind, c.reltuples::bigint, pg_total_relation_size(c.oid),"
                 " pg_table_size(c.oid), pg_indexes_size(c.oid), c.relname"
                 " from pg_class c join pg_namespace n on n.oid = c.relnamespace"
                 " where n.nspname = '" sq "' and c.relkind in ('r','p','m','v','f')"
                 " order by pg_total_relation_size(c.oid) desc, c.relname") 6)))
    (when (and info tabs)
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
                                               (psql--nth-or r 5 "")))
                             tabs))
                 (line (if (equal? (current-buffer) buf) (buffer-line) 0)))
            (psql--lm-begin! buf)
            (psql--view-set! buf (list "schema" s))
            (section-begin)
            (section-line (string-append "Schema: " s "   Owner: " owner "   "
                                         (number->string (length rows)) " relations · "
                                         (psql--human (psql--sum (map (lambda (r) (nth r 2)) rows))))
                          "psql-header")
            (when (not (equal? desc "")) (section-line desc "psql-dim"))
            (psql--emit-hint "RET/g table info · ^ dashboard · r refresh · s query · Y copy · q quit")
            (section-open 'psql-relations "Relations" "psql-section")
            (if (null? rows)
                (section-line "    (no relations)" "psql-dim")
                (psql--emit-rows
                 (list "NAME" "TYPE" "~ROWS" "TOTAL" "TABLE" "INDEXES")
                 rows
                 (lambda (r)
                   (if (psql--sizeless? (nth r 0))
                       (list (nth r 5) (psql--kind (nth r 0)) "-" "-" "-" "-")
                       (list (nth r 5) (psql--kind (nth r 0)) (psql--rows-h (nth r 1))
                             (psql--human (nth r 2)) (psql--human (nth r 3))
                             (psql--human (nth r 4)))))
                 (lambda (r) (psql--record "table" s (nth r 5)))
                 #f))
            (section-close 'psql-relations)
            (section-render buf "psql-mode")
            (goto-line line))))))

;; ── table buffer ──────────────────────────────────────────────────────────────
(define (psql--table-buffer s t) (string-append "*psql-table:" s "." t "*"))
(define (psql--contype c)
  (cond ((equal? c "p") "primary key")
        ((equal? c "f") "foreign key")
        ((equal? c "u") "unique")
        ((equal? c "c") "check")
        ((equal? c "x") "exclusion")
        (else c)))

;; ── column distributions ────────────────────────────────────────────────────
;; The table view's Distributions section, from pg_stats (catalog only — no
;; table scan; needs the table to have been ANALYZEd). For numeric and
;; date/timestamp columns, pg_stats.histogram_bounds splits the values into
;; equal-COUNT buckets, so a narrow bucket means dense values: spreading each
;; bucket's share evenly across its width gives a density curve, drawn as a
;; sparkline by the editor's plot.scm.

;; plot.scm's sparkline function, or #f on editors without it. Looked up through
;; eval-string: naming it directly would make this whole file fail to load on
;; older builds (Steel rejects a unit over one unknown identifier).
(define psql--sparkline
  (if (member "plot-sparkline-string" (function-list))
      (eval-string "plot-sparkline-string")
      #f))
(define psql--spark-bins 24)

;; Consecutive pairs of a sorted bounds list: the histogram's buckets.
(define (psql--buckets bounds)
  (if (or (null? bounds) (null? (cdr bounds)))
      '()
      (cons (list (car bounds) (cadr bounds)) (psql--buckets (cdr bounds)))))

;; Equal-count bucket bounds → `bins` equal-WIDTH densities over [first, last],
;; or #f when there's no spread to draw. A zero-width bucket (a heavily repeated
;; value) puts its whole share in the bin holding that value.
(define (psql--density bounds bins)
  (let* ((bks (psql--buckets bounds))
         (lo  (if (null? bounds) 0 (car bounds)))
         (hi  (if (null? bounds) 0 (last bounds))))
    (if (or (null? bks) (not (> hi lo)))
        #f
        (let ((w (/ (- hi lo) bins)))
          (let loop ((k 0) (acc '()))
            (if (= k bins)
                (reverse acc)
                (let* ((x0 (+ lo (* k w)))
                       (end? (= k (- bins 1)))
                       (x1 (if end? hi (+ x0 w)))
                       (share
                        (lambda (bk)
                          (let ((a (car bk)) (b (cadr bk)))
                            (if (= a b)
                                (if (and (>= a x0) (or (< a x1) (and end? (<= a x1)))) 1.0 0.0)
                                (/ (max 0.0 (- (min b x1) (max a x0))) (- b a)))))))
                  (loop (+ k 1) (cons (psql--sum (map share bks)) acc)))))))))

;; "12.5,40,99" → (12.5 40 99), dropping anything unparsable.
(define (psql--number-list s)
  (filter (lambda (x) x)
          (map string->number (filter (lambda (x) (not (equal? x ""))) (split-many s ",")))))

;; `n` with exactly two decimals, built from integers — Steel's number->string
;; can print a rounded float as 18.740000000000002.
(define (psql--fixed2 n)
  (let* ((c (inexact->exact (round (* (abs n) 100))))
         (frac (remainder c 100)))
    (string-append (if (< n 0) "-" "")
                   (number->string (quotient c 100)) "."
                   (if (< frac 10) "0" "") (number->string frac))))

;; A histogram edge, shortened for the RANGE column: long numbers to 2 decimals
;; (whole numbers from 1000 up), timestamps to the minute; short values as-is.
(define (psql--short-edge v)
  (let ((n (string->number v)))
    (cond ((<= (string-length v) 10) v)
          (n (if (>= (abs n) 1000)
                 (number->string (inexact->exact (round n)))
                 (psql--fixed2 n)))
          ((and (>= (string-length v) 16) (equal? (substring v 4 5) "-")) (substring v 0 16))
          (else v))))

;; pg_stats null_frac → "0%", "<1%", "37%".
(define (psql--null-pct s)
  (let ((f (string->number s)))
    (cond ((not f) "")
          ((= f 0) "0%")
          ((< f 0.01) "<1%")
          (else (string-append (number->string (inexact->exact (round (* 100 f)))) "%")))))

;; pg_stats n_distinct: positive = a count; negative = minus the fraction of
;; rows (-1 = every row distinct).
(define (psql--distinct s)
  (let ((n (string->number s)))
    (cond ((not n) "")
          ((= n -1) "unique")
          ((< n 0) (string-append (number->string (inexact->exact (round (* -100 n)))) "% of rows"))
          (else (number->string (inexact->exact (round n)))))))

;; Per-column stats rows: (null_frac n_distinct min max bounds attname). The
;; histogram cast is limited to types that convert cleanly — one bad cast would
;; fail the whole query. min/max are clipped and `|`-free (only the LAST field
;; may hold a `|`). → rows, or #f if the query failed (never fatal to the view).
(define (psql--column-stats s t oid)
  (let* ((arr "s.histogram_bounds::text::text[]")
         (edge (lambda (i)
                 (string-append "coalesce(left(replace((" arr ")[" i "], '|', '¦'), 30), '')")))
         (sql (string-append
               "select s.null_frac::text, s.n_distinct::text, "
               (edge "1") ", " (edge (string-append "array_length(" arr ", 1)")) ", "
               "coalesce(case"
               " when a.atttypid in ('int2'::regtype, 'int4'::regtype, 'int8'::regtype,"
               "  'float4'::regtype, 'float8'::regtype, 'numeric'::regtype)"
               "  then (select string_agg(v::text, ',') from unnest(s.histogram_bounds::text::float8[]) v)"
               " when a.atttypid in ('date'::regtype, 'timestamp'::regtype, 'timestamptz'::regtype)"
               "  then (select string_agg(extract(epoch from v)::text, ',')"
               "        from unnest(s.histogram_bounds::text::timestamptz[]) v)"
               " end, ''), s.attname"
               " from pg_stats s"
               " join pg_attribute a on a.attrelid = " oid " and a.attname = s.attname"
               " where s.schemaname = '" (psql--sq s) "' and s.tablename = '" (psql--sq t) "'"
               " and not s.inherited order by a.attnum"))
         (r (psql--run-full (append (psql--conn)
                                    (list "-X" "-q" "-A" "-t" "-P" "pager=off" "-c" sql)))))
    (if (equal? (car r) "0")
        (map (lambda (ln) (psql--fields-n ln 6)) (psql--lines (nth r 1)))
        #f)))

;; The Distributions section: one row per analyzed column; the sparkline is the
;; last cell, colored with an accent over its bytes.
(define (psql--emit-distributions s t oid)
  (let ((rows (psql--column-stats s t oid)))
    (section-open 'psql-distributions
                  (string-append "Distributions ("
                                 (if rows (number->string (length rows)) "?") ")")
                  "psql-section")
    (cond
      ((not rows) (section-line "    (statistics unavailable)" "psql-dim"))
      ((null? rows) (section-line "    (no statistics yet — run ANALYZE)" "psql-dim"))
      (else
       (let* ((cells
               (map (lambda (r)
                      (let* ((lo (psql--nth-or r 2 ""))
                             (hi (psql--nth-or r 3 ""))
                             (dens (if psql--sparkline
                                       (psql--density (psql--number-list (psql--nth-or r 4 ""))
                                                      psql--spark-bins)
                                       #f)))
                        (append
                         (list (psql--nth-or r 5 "")
                               (psql--null-pct (psql--nth-or r 0 ""))
                               (psql--distinct (psql--nth-or r 1 ""))
                               (if (equal? lo "")
                                   ""
                                   (string-append (psql--short-edge lo) " … " (psql--short-edge hi))))
                         (if psql--sparkline
                             (list (if dens (psql--sparkline dens 'min 0) ""))
                             '()))))
                    rows))
              (header (append (list "COLUMN" "NULLS" "DISTINCT" "RANGE")
                              (if psql--sparkline (list "DISTRIBUTION") '())))
              (ws (psql--widths (cons header cells))))
         (section-line (string-append "    " (psql--fmt header ws)) "psql-dim")
         (for-each
          (lambda (c)
            (let* ((b (section-point-byte))
                   (text (string-append "    " (psql--fmt c ws)))
                   (spark (if psql--sparkline (nth c 4) ""))
                   (end (utf8-length text)))
              (section-line text #f)
              (when (not (equal? spark ""))
                (section-accent (+ b (- end (utf8-length spark))) (+ b end) "plot-series-0"))))
          cells))))
    (section-close 'psql-distributions)
    (section-line "" #f)))

(define (psql--render-table s t)
  (let* ((oid (psql--reloid s t))
         (ov (psql--query
              (string-append
               "select c.relkind, pg_get_userbyid(c.relowner), c.reltuples::bigint,"
               " pg_size_pretty(pg_total_relation_size(c.oid)),"
               " pg_size_pretty(pg_table_size(c.oid)),"
               " pg_size_pretty(pg_indexes_size(c.oid))"
               " from pg_class c where c.oid = " oid) 6)))
    (when ov
      (if (null? ov)
          (message (string-append "psql: no such relation — " s "." t))
          (let* ((o     (car ov))
                 (kind  (psql--nth-or o 0 ""))
                 (buf   (psql--table-buffer s t))
                 (stats (psql--query
                         (string-append
                          "select coalesce(seq_scan,0), coalesce(idx_scan,0),"
                          " coalesce(n_live_tup,0), coalesce(n_dead_tup,0),"
                          " coalesce(date_trunc('second', greatest(last_vacuum, last_autovacuum))::text, 'never'),"
                          " coalesce(date_trunc('second', greatest(last_analyze, last_autoanalyze))::text, 'never')"
                          " from pg_stat_all_tables"
                          " where schemaname = '" (psql--sq s) "' and relname = '" (psql--sq t) "'") 6))
                 (cols (psql--query
                        (string-append
                         "select a.attnum, format_type(a.atttypid, a.atttypmod),"
                         " case when a.attnotnull then 'not null' else '' end,"
                         " a.attname, coalesce(pg_get_expr(d.adbin, d.adrelid), '')"
                         " from pg_attribute a"
                         " left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum"
                         " where a.attrelid = " oid " and a.attnum > 0 and not a.attisdropped"
                         " order by a.attnum") 5))
                 (idxs (psql--query
                        (string-append
                         "select pg_size_pretty(pg_relation_size(i.indexrelid)),"
                         " coalesce(st.idx_scan, 0), ic.relname, pg_get_indexdef(i.indexrelid)"
                         " from pg_index i join pg_class ic on ic.oid = i.indexrelid"
                         " left join pg_stat_all_indexes st on st.indexrelid = i.indexrelid"
                         " where i.indrelid = " oid
                         " order by pg_relation_size(i.indexrelid) desc, ic.relname") 4))
                 (cons- (psql--query
                         (string-append
                          "select con.contype, con.conname, pg_get_constraintdef(con.oid)"
                          " from pg_constraint con where con.conrelid = " oid
                          " order by con.contype, con.conname") 3))
                 (line (if (equal? (current-buffer) buf) (buffer-line) 0)))
            (when (and stats cols idxs cons-)
              (psql--lm-begin! buf)
              (psql--view-set! buf (list "table" s t))
              (section-begin)
              (section-line (string-append (psql--kind kind) ": " s "." t
                                           "   Owner: " (psql--nth-or o 1 "?")
                                           "   Total: " (psql--nth-or o 3 "?")
                                           " (table " (psql--nth-or o 4 "?")
                                           " · indexes " (psql--nth-or o 5 "?") ")")
                            "psql-header")
              (let ((st (if (null? stats) '() (car stats))))
                (section-line
                 (string-append "~" (psql--rows-h (psql--num (psql--nth-or o 2 "-1"))) " rows"
                                "   live " (psql--nth-or st 2 "-")
                                " · dead " (psql--nth-or st 3 "-")
                                "   scans: seq " (psql--nth-or st 0 "-")
                                " · idx " (psql--nth-or st 1 "-")
                                "   vacuum: " (psql--nth-or st 4 "-")
                                " · analyze: " (psql--nth-or st 5 "-"))
                 #f))
              (psql--emit-hint "^ up to schema · r refresh · s query · q quit")
              ;; columns
              (section-open 'psql-columns
                            (string-append "Columns (" (number->string (length cols)) ")")
                            "psql-section")
              (if (null? cols)
                  (section-line "    (none)" "psql-dim")
                  (psql--emit-rows (list "#" "NAME" "TYPE" "NULL" "DEFAULT")
                                   cols
                                   (lambda (c) (list (psql--nth-or c 0 "")
                                                     (psql--nth-or c 3 "")
                                                     (psql--nth-or c 1 "")
                                                     (psql--nth-or c 2 "")
                                                     (psql--nth-or c 4 "")))
                                   #f #f))
              (section-close 'psql-columns)
              (section-line "" #f)
              (psql--emit-distributions s t oid)
              ;; indexes
              (section-open 'psql-indexes
                            (string-append "Indexes (" (number->string (length idxs)) ")")
                            "psql-section")
              (if (null? idxs)
                  (section-line "    (none)" "psql-dim")
                  (psql--emit-rows (list "NAME" "SIZE" "SCANS" "DEFINITION")
                                   idxs
                                   (lambda (i) (list (psql--nth-or i 2 "")
                                                     (psql--nth-or i 0 "")
                                                     (psql--nth-or i 1 "")
                                                     (psql--nth-or i 3 "")))
                                   #f #f))
              (section-close 'psql-indexes)
              (section-line "" #f)
              ;; constraints
              (section-open 'psql-constraints
                            (string-append "Constraints (" (number->string (length cons-)) ")")
                            "psql-section")
              (if (null? cons-)
                  (section-line "    (none)" "psql-dim")
                  (psql--emit-rows (list "TYPE" "NAME" "DEFINITION")
                                   cons-
                                   (lambda (c) (list (psql--contype (psql--nth-or c 0 ""))
                                                     (psql--nth-or c 1 "")
                                                     (psql--nth-or c 2 "")))
                                   #f #f))
              (section-close 'psql-constraints)
              ;; view definition
              (when (member kind (list "v" "m"))
                (section-line "" #f)
                (section-open 'psql-viewdef "Definition" "psql-section")
                (let ((def (psql--raw (string-append "select pg_get_viewdef(" oid ", true)"))))
                  (if (or (not def) (equal? def ""))
                      (section-line "    (unavailable)" "psql-dim")
                      (for-each (lambda (l) (section-line (string-append "    " l) #f))
                                (split-many def "\n"))))
                (section-close 'psql-viewdef))
              (section-render buf "psql-mode")
              (goto-line line)))))))

;; ── entry / navigation commands ───────────────────────────────────────────────
(define-command (psql-dashboard) (psql--authed psql--render-dashboard))

;; Refresh whatever psql buffer we're in.
(define-command (psql-refresh)
  (let ((v (psql--view (current-buffer))))
    (if (not v)
        (message "psql: not a psql buffer")
        (psql--authed
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
        (psql--authed
          (lambda ()
            (cond ((equal? (nth e 1) "schema") (psql--render-schema (nth e 2)))
                  ((equal? (nth e 1) "table")  (psql--render-table (nth e 2) (nth e 3)))))))))

;; ^: go up a level (table → its schema, schema → dashboard).
(define-command (psql-up)
  (let ((v (psql--view (current-buffer))))
    (cond ((and v (equal? (car v) "table"))  (psql--authed (lambda () (psql--render-schema (nth v 1)))))
          ((and v (equal? (car v) "schema")) (psql--authed psql--render-dashboard))
          (else (message "psql: already at the top")))))

(define-command (psql-toggle-fold) (section-toggle-at-point))

(define (psql--apply-url u)
  (set-option "psql-url" (trim-end (trim-start u)))
  (psql--st! 'cat-state "")   ; new database → stale completion catalog
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
    (cond
     ((psql--blank? sql) (message "psql: buffer is empty"))
     ((async-lane-live? "psql")
      (message "psql: a query is already running — C-g cancels it"))
     (else (psql--authed (lambda () (psql--run-sql sql)))))))

;; The body of psql-run-buffer, once a password (if needed) is in hand.
(define (psql--run-sql sql)
  (let ((file (psql--query-file))
        (status (psql--status-file))
        (u (psql--conn-url)))
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
      'psql--run-output 'psql--run-exit (psql--env))
    (message "psql: running… (C-g in the query buffer cancels)")))

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

;; Walk the raw stream: split on the record sentinel; a chunk whose first line
;; is data extends the current result set (embedded newlines and all); a chunk
;; opening with meta lines ends the set — the metas pass through and any
;; remainder line is the NEXT set's header.
(define (psql--faced-lines raw)
  (let loop ((chunks (split-many raw psql--RS)) (set '()) (acc '()))
    (define (flush acc)
      (if (null? set)
          acc
          (append (reverse (psql--format-block (reverse set)))
                  (if (null? acc) acc (cons (list "" #f) acc)))))
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
                            (cons (list (car ls) (psql--result-line-face (car ls))) acc))))
                 (else
                  ;; remainder — the next result set's header record
                  (loop (cdr chunks) (list (string-join ls "\n")) acc)))))))))

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
    (if user-cancelled
        (message "psql: query cancelled")
        (let* ((raw (string-join (reverse (psql--st 'async-out)) "\n"))
               (out (if (psql--blank? raw)
                        "(no output)"
                        (psql--format-results (trim-end raw))))
               ;; 141 = SIGPIPE = head hit the raw-stream backstop
               (note (cond ((psql--st 'capped)
                            "\n\n… truncated at psql-max-rows lines (auto-cancelled) …")
                           ((equal? code "141")
                            "\n\n… truncated at psql-max-output bytes …")
                           (else "")))
               (truncated (not (equal? note ""))))
          (write-file (psql--results-file) (string-append out note "\n"))
          ;; Show results in the OTHER window, so the query stays visible below.
          (when (equal? (current-buffer) "*psql-query*") (other-window))
          (kill-buffer-named "results.org")   ; drop a stale view so find-file re-reads
          (open-file (psql--results-file))
          (message (cond (truncated "psql: done — output truncated, see results.org")
                         ((equal? code "0") "psql: done — see results.org")
                         (else "psql: query failed — see results.org")))
          (when (and (not (equal? code "0")) (psql--auth-failed? raw))
            (psql--password-rejected))))))

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
  (if (psql--url-locked?)
      psql--locked-error
      (psql--babel-run-unlocked body)))
(define (psql--babel-run-unlocked body)
  (let* ((u (psql--conn-url))
         (r (call-process-env "/bin/sh"
              (list "-c" (string-append
                          (psql--sh-quote (psql--command)) " "
                          (if (equal? u "") "" (string-append "-d " (psql--sh-quote u) " "))
                          "-v FETCH_COUNT=100 -X -q -A"
                          " -P recordsep=" psql--RS " -P fieldsep=" psql--FS
                          " -P pager=off -f - 2>&1"
                          " | head -c " (number->string psql--babel-max-bytes)))
              (string-append body "\n")
              (psql--env)))
         (out (trim-end (psql--format-results (trim-end (nth r 1)))))
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
;; Not while psql-url is a locked secret: that's "not yet", not "failed" (a
;; failure sticks until psql-catalog-refresh), so completion retries once a
;; command has unlocked it.
(define (psql--catalog-ensure!)
  (when (and (equal? (psql--st 'cat-state) "") (not (psql--url-locked?)))
    (psql--catalog-refresh!)))

(define-command (psql-catalog-refresh)
  (psql--authed
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
                    (list "s" "SQL query"        'psql-query)
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
