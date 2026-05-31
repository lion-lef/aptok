# Integration spec for the real SQLite FFI driver.
#
# This file is intentionally **not** named `*_spec.cr`, so `crystal spec`
# (which auto-discovers only `spec/**/*_spec.cr`) does not pick it up — the
# default suite stays dependency-free. Run it explicitly, with `libsqlite3`
# available on the system:
#
#     crystal spec spec/drivers/sqlite_driver.cr
#
require "spec"
require "../../src/aptork"
require "../../src/store/sqlite"

private def new_store
  conn = Aptork::SqliteConnection.open(":memory:")
  {conn, Aptork::SqlKvStore.new(conn, dialect: Aptork::SqlDialect::Sqlite)}
end

describe Aptork::SqliteConnection do
  it "stores, reads, and deletes KV values against real SQLite" do
    _conn, store = new_store
    store.set("actor:alice", "ok")
    store.get("actor:alice").should eq("ok")
    store.delete("actor:alice")
    store.get("actor:alice").should be_nil
  end

  it "expires KV values past their TTL" do
    _conn, store = new_store
    store.set("temp", "value", ttl: 5.milliseconds)
    store.get("temp").should eq("value")
    sleep 20.milliseconds
    store.get("temp").should be_nil
  end

  it "lists KV values by prefix and escapes LIKE metacharacters" do
    _conn, store = new_store
    store.set("actor:alice", "alice")
    store.set("actor:bob", "bob")
    store.set("object:note", "note")
    store.set("act%or", "literal")

    store.list("actor:").map(&.key).should eq(["actor:alice", "actor:bob"])
    # The '%' must be treated literally, not as a LIKE wildcard.
    store.list("act%").map(&.key).should eq(["act%or"])
  end

  it "compares and swaps atomically with real SQL" do
    _conn, store = new_store
    store.cas("lock", nil, "alice").should be_true
    store.cas("lock", nil, "bob").should be_false
    store.cas("lock", "alice", "bob").should be_true
    store.cas("lock", "alice", "carol").should be_false
    store.get("lock").should eq("bob")
  end

  it "processes, retries, and dead-letters queue messages" do
    conn = Aptork::SqliteConnection.open(":memory:")
    queue = Aptork::SqlMessageQueue.new(conn, dialect: Aptork::SqlDialect::Sqlite)
    queue.enqueue("outbox", Aptork.object("Note", "https://local.example/notes/1"))
    queue.enqueue("outbox", Aptork.object("Note", "https://local.example/notes/2"))
    queue.depth("outbox").should eq(2)

    processed = [] of String
    queue.process_one("outbox") { |m| processed << m.payload["id"].as_s }
    processed.should eq(["https://local.example/notes/1"])
    queue.depth("outbox").should eq(1)

    policy = Aptork::RetryPolicy.new(max_attempts: 1)
    queue.enqueue("dlq", Aptork.object("Note", "https://local.example/notes/fail"))
    queue.process_one("dlq", policy) { |_m| raise "boom" }.should eq(Aptork::QueueProcessResult::Dead)
    queue.dead_messages("dlq").size.should eq(1)
  end
end
