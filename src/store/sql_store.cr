require "random/secure"

module Aptok
  # A value that can be bound to a SQL statement parameter or returned from a
  # query. Drivers return text/integer columns; `Nil` represents SQL `NULL`.
  alias SqlValue = String | Int32 | Int64 | Nil

  enum SqlDialect
    Sqlite
    Postgres
  end

  # Abstract execution surface that `SqlKvStore` and `SqlMessageQueue` depend on.
  #
  # Statements are written with positional `?` placeholders; the store rewrites
  # them for the configured `SqlDialect` (Postgres uses `$1`, `$2`, …) before
  # calling the connection. Implementations only need to run an already
  # dialect-correct statement.
  #
  # Two concrete adapters ship with Aptok:
  #
  # - `Aptok::PostgresConnection`, backed by `will/crystal-pg`, available via
  #   `require "aptok/store/postgres"`.
  # - `Aptok::SqliteConnection`, backed by `crystal-lang/crystal-sqlite3`,
  #   available via `require "aptok/store/sqlite"`.
  module SqlConnection
    def dialect : SqlDialect
      SqlDialect::Sqlite
    end

    # Executes a statement that returns no rows and returns the number of rows
    # affected.
    abstract def execute(sql : String, args : Array(SqlValue)) : Int64

    # Executes a query and returns all result rows.
    abstract def query(sql : String, args : Array(SqlValue)) : Array(Array(SqlValue))
  end

  # Shared helpers for translating the `?`-placeholder statements used by the
  # SQL-backed stores into the configured dialect, and for coercing returned
  # column values.
  module SqlStatements
    # Rewrites positional `?` placeholders for the dialect. Our statements never
    # contain `?` inside string literals, so a straight scan is safe.
    def self.prepare(sql : String, dialect : SqlDialect) : String
      return sql if dialect.sqlite?

      index = 0
      String.build do |io|
        sql.each_char do |char|
          if char == '?'
            index += 1
            io << '$' << index
          else
            io << char
          end
        end
      end
    end

    def self.to_i64?(value : SqlValue) : Int64?
      case value
      when Int64  then value
      when Int32  then value.to_i64
      when String then value.to_i64?
      else             nil
      end
    end

    def self.to_s?(value : SqlValue) : String?
      case value
      when String then value
      when Int32  then value.to_s
      when Int64  then value.to_s
      else             nil
      end
    end
  end

  # A `KvStore` backed by any SQL database reachable through a `SqlConnection`.
  # Works against SQLite and PostgreSQL using portable SQL (`INSERT … ON CONFLICT
  # … DO UPDATE`). TTLs are stored as an absolute Unix-millisecond expiry and
  # enforced lazily on read, plus atomically on compare-and-swap.
  #
  # ```
  # conn = Aptok::SqliteConnection.open("federation.db")
  # store = Aptok::SqlKvStore.new(conn)
  # store.set("actor:alice", "{...}")
  # store.get("actor:alice")
  # ```
  class SqlKvStore
    include KvStore

    @dialect : SqlDialect

    def initialize(@connection : SqlConnection, dialect : SqlDialect? = nil, @table : String = "aptok_kv", migrate : Bool = true)
      @dialect = dialect || @connection.dialect
      self.migrate if migrate
    end

    # Creates the backing table if it does not already exist.
    def migrate : Nil
      exec(<<-SQL)
        /* aptok:kv_migrate */
        CREATE TABLE IF NOT EXISTS #{@table} (
          k TEXT PRIMARY KEY,
          v TEXT NOT NULL,
          expires_at BIGINT
        )
        SQL
    end

    def get(key : String) : String?
      now = now_ms
      rows = query(<<-SQL, [key.as(SqlValue)])
        /* aptok:kv_get */
        SELECT v, expires_at FROM #{@table} WHERE k = ?
        SQL
      row = rows.first?
      return nil unless row

      if expired?(row[1]?, now)
        delete(key)
        return nil
      end
      SqlStatements.to_s?(row[0]?)
    end

    def set(key : String, value : String, ttl : Time::Span? = nil) : Nil
      exec(<<-SQL, [key.as(SqlValue), value.as(SqlValue), expiry(ttl)])
        /* aptok:kv_set */
        INSERT INTO #{@table} (k, v, expires_at) VALUES (?, ?, ?)
        ON CONFLICT (k) DO UPDATE SET v = excluded.v, expires_at = excluded.expires_at
        SQL
    end

    def delete(key : String) : Nil
      exec(<<-SQL, [key.as(SqlValue)])
        /* aptok:kv_delete */
        DELETE FROM #{@table} WHERE k = ?
        SQL
    end

    def cas(key : String, expected_value : String?, new_value : String, ttl : Time::Span? = nil) : Bool
      now = now_ms
      if expected_value.nil?
        # Insert only when absent, or overwrite an expired row — atomic in both
        # SQLite and Postgres via a conditional ON CONFLICT DO UPDATE.
        affected = exec(<<-SQL, [key.as(SqlValue), new_value.as(SqlValue), expiry(ttl), now.as(SqlValue)])
          /* aptok:kv_cas_insert */
          INSERT INTO #{@table} (k, v, expires_at) VALUES (?, ?, ?)
          ON CONFLICT (k) DO UPDATE SET v = excluded.v, expires_at = excluded.expires_at
          WHERE #{@table}.expires_at IS NOT NULL AND #{@table}.expires_at <= ?
          SQL
        affected > 0
      else
        affected = exec(<<-SQL, [new_value.as(SqlValue), expiry(ttl), key.as(SqlValue), expected_value.as(SqlValue), now.as(SqlValue)])
          /* aptok:kv_cas_update */
          UPDATE #{@table} SET v = ?, expires_at = ?
          WHERE k = ? AND v = ? AND (expires_at IS NULL OR expires_at > ?)
          SQL
        affected > 0
      end
    end

    def list(prefix : String? = nil) : Array(KvStoreEntry)
      now = now_ms
      rows =
        if prefix
          query(<<-SQL, [like_prefix(prefix).as(SqlValue)])
            /* aptok:kv_list_prefix */
            SELECT k, v, expires_at FROM #{@table} WHERE k LIKE ? ESCAPE '\\' ORDER BY k
            SQL
        else
          query(<<-SQL)
            /* aptok:kv_list */
            SELECT k, v, expires_at FROM #{@table} ORDER BY k
            SQL
        end

      entries = [] of KvStoreEntry
      rows.each do |row|
        key = SqlStatements.to_s?(row[0]?)
        value = SqlStatements.to_s?(row[1]?)
        next unless key && value
        if expired?(row[2]?, now)
          delete(key)
          next
        end
        entries << KvStoreEntry.new(key, value)
      end
      entries
    end

    private def expiry(ttl : Time::Span?) : SqlValue
      ttl ? (now_ms + ttl.not_nil!.total_milliseconds.to_i64) : nil
    end

    private def expired?(value : SqlValue, now : Int64) : Bool
      expires_at = SqlStatements.to_i64?(value)
      !!(expires_at && now >= expires_at)
    end

    private def like_prefix(prefix : String) : String
      escaped = prefix.gsub("\\", "\\\\").gsub("%", "\\%").gsub("_", "\\_")
      "#{escaped}%"
    end

    private def now_ms : Int64
      Time.utc.to_unix_ms
    end

    private def exec(sql : String, args : Array(SqlValue) = [] of SqlValue) : Int64
      @connection.execute(SqlStatements.prepare(sql, @dialect), args)
    end

    private def query(sql : String, args : Array(SqlValue) = [] of SqlValue) : Array(Array(SqlValue))
      @connection.query(SqlStatements.prepare(sql, @dialect), args)
    end
  end

  # A `MessageQueue` backed by a SQL database. Messages live in a single table;
  # delivery claims a ready row with an atomic conditional `DELETE`, so multiple
  # workers can poll the same queue without double-processing. Failed messages
  # are re-enqueued with exponential backoff, then dead-lettered (rows flagged
  # `dead = 1`) once `RetryPolicy#max_attempts` is reached.
  class SqlMessageQueue
    include MessageQueue

    # Process-wide monotonic sequence so that messages enqueued at the same
    # millisecond keep first-in/first-out ordering: each generated row id is
    # `<zero-padded seq><random>`, which sorts lexicographically by insertion
    # order while staying unique across processes.
    @@sequence = Atomic(Int64).new(0_i64)

    @dialect : SqlDialect

    def initialize(@connection : SqlConnection, dialect : SqlDialect? = nil, @table : String = "aptok_queue", migrate : Bool = true)
      @dialect = dialect || @connection.dialect
      self.migrate if migrate
    end

    def migrate : Nil
      exec(<<-SQL)
        /* aptok:queue_migrate */
        CREATE TABLE IF NOT EXISTS #{@table} (
          id TEXT PRIMARY KEY,
          queue TEXT NOT NULL,
          payload TEXT NOT NULL,
          attempts BIGINT NOT NULL DEFAULT 0,
          available_at BIGINT NOT NULL,
          ordering_key TEXT,
          dead BIGINT NOT NULL DEFAULT 0
        )
        SQL
    end

    def enqueue(queue : String, payload : JsonMap, options : EnqueueOptions = EnqueueOptions.new) : Nil
      available_at = Time.utc
      available_at += options.delay.not_nil! if options.delay
      insert(QueueMessage.new(queue, payload, available_at: available_at, ordering_key: options.ordering_key))
    end

    def enqueue_many(queue : String, payloads : Enumerable(JsonMap), options : EnqueueOptions = EnqueueOptions.new) : Nil
      available_at = Time.utc
      available_at += options.delay.not_nil! if options.delay
      payloads.each do |payload|
        insert(QueueMessage.new(queue, payload, available_at: available_at, ordering_key: options.ordering_key))
      end
    end

    def depth(queue : String) : Int32
      rows = query(<<-SQL, [queue.as(SqlValue)])
        /* aptok:queue_depth */
        SELECT COUNT(*) FROM #{@table} WHERE queue = ? AND dead = 0
        SQL
      (SqlStatements.to_i64?(rows.first?.try(&.[0]?)) || 0_i64).to_i
    end

    def get_depth(queue : String, now : Time = Time.utc) : QueueDepth
      queued = depth(queue)
      rows = query(<<-SQL, [queue.as(SqlValue), now.to_unix_ms.as(SqlValue)])
        /* aptok:queue_ready_count */
        SELECT COUNT(*) FROM #{@table} WHERE queue = ? AND dead = 0 AND available_at <= ?
        SQL
      ready = (SqlStatements.to_i64?(rows.first?.try(&.[0]?)) || 0_i64).to_i
      QueueDepth.new(queued, ready, queued - ready)
    end

    def ready(queue : String, now : Time = Time.utc, limit : Int32 = 1) : Array(QueueMessage)
      rows = query(<<-SQL, [queue.as(SqlValue), now.to_unix_ms.as(SqlValue), limit.to_i64.as(SqlValue)])
        /* aptok:queue_ready */
        SELECT id, queue, payload, attempts, available_at, ordering_key
        FROM #{@table} WHERE queue = ? AND dead = 0 AND available_at <= ?
        ORDER BY available_at, id LIMIT ?
        SQL
      rows.compact_map { |row| decode_row(row) }
    end

    def process_one(queue : String, policy : RetryPolicy = RetryPolicy.new, now : Time = Time.utc, &handler : QueueMessage -> Nil) : QueueProcessResult
      loop do
        candidate = next_ready(queue, now)
        return QueueProcessResult::Deferred unless candidate

        id, message = candidate
        claimed = exec(<<-SQL, [id.as(SqlValue)])
          /* aptok:queue_claim */
          DELETE FROM #{@table} WHERE id = ?
          SQL
        # Another worker won the race for this row; try the next one.
        next if claimed == 0

        begin
          handler.call(message)
          return QueueProcessResult::Processed
        rescue
          attempts = message.attempts + 1
          retried = QueueMessage.new(
            message.queue,
            message.payload,
            attempts,
            now + retry_delay(policy, attempts),
            message.ordering_key
          )
          if attempts >= policy.max_attempts
            insert(retried, dead: true)
            return QueueProcessResult::Dead
          else
            insert(retried)
            return QueueProcessResult::Retried
          end
        end
      end
    end

    def listen(queue : String, policy : RetryPolicy = RetryPolicy.new, now : Time = Time.utc, limit : Int32? = nil, &handler : QueueMessage -> Nil) : Array(QueueProcessResult)
      results = [] of QueueProcessResult
      loop do
        break if limit && results.size >= limit
        result = process_one(queue, policy, now) { |message| handler.call(message) }
        break if result == QueueProcessResult::Deferred
        results << result
      end
      results
    end

    # Returns the dead-lettered messages for a queue (rows flagged `dead = 1`).
    def dead_messages(queue : String) : Array(QueueMessage)
      rows = query(<<-SQL, [queue.as(SqlValue)])
        /* aptok:queue_dead */
        SELECT id, queue, payload, attempts, available_at, ordering_key
        FROM #{@table} WHERE queue = ? AND dead = 1 ORDER BY available_at, id
        SQL
      rows.compact_map { |row| decode_row(row) }
    end

    private def next_ready(queue : String, now : Time) : Tuple(String, QueueMessage)?
      rows = query(<<-SQL, [queue.as(SqlValue), now.to_unix_ms.as(SqlValue)])
        /* aptok:queue_next */
        SELECT id, queue, payload, attempts, available_at, ordering_key
        FROM #{@table} WHERE queue = ? AND dead = 0 AND available_at <= ?
        ORDER BY available_at, id LIMIT 1
        SQL
      row = rows.first?
      return nil unless row

      id = SqlStatements.to_s?(row[0]?)
      message = decode_row(row)
      return nil unless id && message

      {id, message}
    end

    private def insert(message : QueueMessage, dead : Bool = false) : Nil
      args = [
        next_id.as(SqlValue),
        message.queue.as(SqlValue),
        message.payload.to_json.as(SqlValue),
        message.attempts.to_i64.as(SqlValue),
        message.available_at.to_unix_ms.as(SqlValue),
        message.ordering_key.as(SqlValue),
        (dead ? 1_i64 : 0_i64).as(SqlValue),
      ]
      exec(<<-SQL, args)
        /* aptok:queue_insert */
        INSERT INTO #{@table} (id, queue, payload, attempts, available_at, ordering_key, dead)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        SQL
    end

    private def next_id : String
      seq = @@sequence.add(1_i64)
      "%016x%s" % {seq, Random::Secure.hex(6)}
    end

    private def decode_row(row : Array(SqlValue)) : QueueMessage?
      queue = SqlStatements.to_s?(row[1]?)
      payload_json = SqlStatements.to_s?(row[2]?)
      return nil unless queue && payload_json

      payload = JsonMap.from_json(payload_json)
      attempts = (SqlStatements.to_i64?(row[3]?) || 0_i64).to_i
      available_at = Time.unix_ms(SqlStatements.to_i64?(row[4]?) || 0_i64)
      ordering_key = SqlStatements.to_s?(row[5]?)
      QueueMessage.new(queue, payload, attempts, available_at, ordering_key)
    end

    private def retry_delay(policy : RetryPolicy, attempts : Int32) : Time::Span
      seconds = policy.initial_delay.total_seconds * (policy.multiplier ** (attempts - 1))
      seconds = {seconds, policy.max_delay.total_seconds}.min
      seconds = seconds * (0.5 + Random.rand) if policy.jitter
      Time::Span.new(seconds: seconds.to_i)
    end

    private def exec(sql : String, args : Array(SqlValue) = [] of SqlValue) : Int64
      @connection.execute(SqlStatements.prepare(sql, @dialect), args)
    end

    private def query(sql : String, args : Array(SqlValue) = [] of SqlValue) : Array(Array(SqlValue))
      @connection.query(SqlStatements.prepare(sql, @dialect), args)
    end
  end
end
