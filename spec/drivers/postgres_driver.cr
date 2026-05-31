# Integration spec for the crystal-pg-backed PostgreSQL driver.
#
# Not named `*_spec.cr`, so `crystal spec` does not auto-run it. It needs a
# reachable PostgreSQL server; point it at one with the connection URL and run
# it explicitly:
#
#     APTOK_TEST_POSTGRES_URL=postgres://user:pass@localhost:5432/db \
#       crystal spec spec/drivers/postgres_driver.cr
#
require "spec"
require "../../src/aptok"
require "../../src/store/postgres"

POSTGRES_URL = ENV["APTOK_TEST_POSTGRES_URL"]?

private def fresh_connection
  Aptok::PostgresConnection.connect(POSTGRES_URL.not_nil!)
end

# A short, unique-ish suffix so repeated runs don't collide on table names.
private def suffix
  Time.utc.to_unix_ms.to_s
end

describe Aptok::PostgresConnection do
  if POSTGRES_URL.nil?
    pending "requires APTOK_TEST_POSTGRES_URL to run Postgres integration tests" { }
  else
    it "authenticates and round-trips KV values" do
      conn = fresh_connection
      store = Aptok::SqlKvStore.new(conn, table: "aptok_kv_#{suffix}")
      store.set("actor:alice", "ok")
      store.get("actor:alice").should eq("ok")
      store.delete("actor:alice")
      store.get("actor:alice").should be_nil
      conn.close
    end

    it "compares and swaps atomically" do
      conn = fresh_connection
      store = Aptok::SqlKvStore.new(conn, table: "aptok_cas_#{suffix}")
      store.cas("lock", nil, "alice").should be_true
      store.cas("lock", nil, "bob").should be_false
      store.cas("lock", "alice", "bob").should be_true
      store.get("lock").should eq("bob")
      conn.close
    end

    it "processes and dead-letters queue messages" do
      conn = fresh_connection
      queue = Aptok::SqlMessageQueue.new(conn, table: "aptok_q_#{suffix}")
      queue.enqueue("outbox", Aptok.object("Note", "https://local.example/notes/1"))
      queue.depth("outbox").should eq(1)
      queue.process_one("outbox") { |_m| }.should eq(Aptok::QueueProcessResult::Processed)
      queue.depth("outbox").should eq(0)

      policy = Aptok::RetryPolicy.new(max_attempts: 1)
      queue.enqueue("dlq", Aptok.object("Note", "https://local.example/notes/fail"))
      queue.process_one("dlq", policy) { |_m| raise "boom" }.should eq(Aptok::QueueProcessResult::Dead)
      queue.dead_messages("dlq").size.should eq(1)
      conn.close
    end
  end
end
