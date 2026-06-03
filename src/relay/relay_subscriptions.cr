require "json"
require "digest/sha256"
require "../store/store"
require "../portable"
require "../federation/federation_types"

module Aptok
  module Relay
    # KvStore-backed registry of a relay's subscribers.
    #
    # Subscriber identifiers are canonicalized with `Aptok.canonical_ap_uri`, so
    # a portable actor that subscribes with a gateway-hinted `ap://` URI and
    # later unsubscribes with the canonical URI (or a compatible gateway URL) is
    # still matched to the same subscription. Each registry instance is scoped to
    # a single relay actor id, so several relays can share one store.
    class Subscriptions
      # Key prefix for stored subscribers.
      SUBSCRIBER_PREFIX = "aptok:relay:subscriber"
      # Key prefix for relayed-activity de-duplication markers.
      RELAYED_PREFIX = "aptok:relay:relayed"

      getter relay : String

      @relay_segment : String
      @subscriber_prefix : String

      def initialize(@store : KvStore, @relay : String, *, prefix : String = SUBSCRIBER_PREFIX)
        @relay_segment = digest(canonical(@relay))
        @subscriber_prefix = "#{prefix}:#{@relay_segment}"
      end

      # Register a subscriber from its resolved actor document. Returns the
      # stored `Recipient`, or nil when the actor lacks an id/inbox. Portable
      # `ap://` inboxes are resolved to gateway delivery URLs automatically.
      def add(actor : JsonMap, *, prefer_shared_inbox : Bool = false) : Recipient?
        recipient = Aptok.recipient_from_actor(actor, prefer_shared_inbox)
        return nil unless recipient
        add(recipient)
      end

      # Register a subscriber from an already-built `Recipient`.
      def add(recipient : Recipient) : Recipient
        @store.set(key_for(recipient.id), recipient_to_json(recipient))
        recipient
      end

      # Remove a subscriber by actor id. Returns true when a subscription
      # existed.
      def remove(actor_id : String) : Bool
        key = key_for(actor_id)
        existed = !@store.get(key).nil?
        @store.delete(key)
        existed
      end

      # Whether `actor_id` is currently subscribed.
      def subscribed?(actor_id : String) : Bool
        !@store.get(key_for(actor_id)).nil?
      end

      # All subscribers as `Recipient` records.
      def recipients : Array(Recipient)
        @store.list(@subscriber_prefix).compact_map do |entry|
          recipient_from_json(entry.value)
        end
      end

      # All subscriber actor ids.
      def actor_ids : Array(String)
        recipients.map(&.id)
      end

      # Number of subscribers.
      def size : Int32
        @store.list(@subscriber_prefix).size
      end

      # Remove every subscriber for this relay.
      def clear : Nil
        @store.list(@subscriber_prefix).each { |entry| @store.delete(entry.key) }
      end

      # Whether `activity_id` has already been relayed (FEP-ae0c: relays SHOULD
      # NOT relay an activity more than once).
      def relayed?(activity_id : String) : Bool
        !@store.get(relayed_key(activity_id)).nil?
      end

      # Mark `activity_id` as relayed, optionally with a time-to-live.
      def mark_relayed(activity_id : String, ttl : Time::Span? = nil) : Nil
        @store.set(relayed_key(activity_id), "1", ttl)
      end

      # Storage key for a subscriber, hashed so arbitrary URIs (with `:` and `/`)
      # produce uniform, collision-free keys across store backends.
      def key_for(actor_id : String) : String
        "#{@subscriber_prefix}:#{digest(canonical(actor_id))}"
      end

      private def relayed_key(activity_id : String) : String
        "#{RELAYED_PREFIX}:#{@relay_segment}:#{digest(activity_id)}"
      end

      private def canonical(value : String) : String
        Aptok.canonical_ap_uri(value) || value
      end

      private def digest(value : String) : String
        Digest::SHA256.hexdigest(value)
      end

      private def recipient_to_json(recipient : Recipient) : String
        JSON.build do |json|
          json.object do
            json.field "id", recipient.id
            json.field "inbox", recipient.inbox
            json.field "actor_ids", recipient.actor_ids
            json.field "shared_inbox", recipient.shared_inbox
          end
        end
      end

      private def recipient_from_json(value : String) : Recipient?
        parsed = JSON.parse(value)
        id = parsed["id"]?.try(&.as_s?)
        inbox = parsed["inbox"]?.try(&.as_s?)
        return nil unless id && inbox

        actor_ids = parsed["actor_ids"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
        shared = parsed["shared_inbox"]?.try(&.as_s?)
        Recipient.new(id, inbox, actor_ids, shared)
      rescue JSON::ParseException
        nil
      end
    end
  end
end
