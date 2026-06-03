require "set"
require "../vocabulary/vocabulary"
require "../portable"
require "../federation/federation_types"

module Aptok
  # FEP-ae0c relay protocol helpers (Mastodon-style and LitePub-style).
  #
  # See: https://codeberg.org/fediverse/fep/src/branch/main/fep/ae0c/fep-ae0c.md
  #
  # The module covers both halves of a relay:
  #
  # * Relay *clients* build subscription, unsubscription and publish activities
  #   with `Relay.subscribe`, `Relay.unsubscribe` and `Relay.announce`.
  # * Relay *servers* classify inbound activities (`Relay.subscription?`,
  #   `Relay.subscription_protocol`, `Relay.unsubscription?`, `Relay.relayable?`),
  #   acknowledge with `Relay.accept`/`Relay.reject`, track subscribers with
  #   `Relay::Subscriptions`, and fan content out with `Relay::Server#relay`.
  #
  # Every helper canonicalizes actor identifiers with FEP-ef61 portable URIs in
  # mind, so the same relay works for classic `https://` actors and portable
  # `ap://did:...` actors without any special-casing by the caller.
  module Relay
    # The relay protocol variant.
    enum Protocol
      # Mastodon-style relay: the subscription `Follow` targets the public
      # pseudo-collection and published activities (`Create`/`Update`/`Delete`/
      # `Move`) are forwarded unchanged to followers.
      Mastodon

      # LitePub-style (Pleroma) relay: the subscription `Follow` targets the
      # relay actor, the relay sends a reciprocal `Follow`, and content is
      # relayed as an `Announce` addressed to the relay's followers collection.
      LitePub
    end

    # ActivityPub actor type required for LitePub relay client actors and
    # commonly used by Mastodon relay actors.
    RELAY_ACTOR_TYPE = "Application"

    # Activity types relayed by FEP-ae0c relays. Mastodon forwards
    # `Create`/`Update`/`Delete`/`Move` and also accepts `Announce`; LitePub
    # relays content with `Announce`.
    RELAYABLE_ACTIVITY_TYPES = %w[Create Update Delete Move Announce]

    # Build a relay server actor document. Defaults to the `Application` type
    # expected for relays and accepts `gateways` for FEP-ef61 portable relays.
    def self.actor(
      id : String,
      preferred_username : String,
      inbox : String,
      outbox : String,
      followers : String,
      name : String? = nil,
      summary : String? = nil,
      following : String? = nil,
      shared_inbox : String? = nil,
      public_key : JsonMap? = nil,
      assertion_methods : Array(JsonMap) = [] of JsonMap,
      gateways : Array(String) = [] of String,
      type : String = RELAY_ACTOR_TYPE
    ) : JsonMap
      Aptok.actor(
        type,
        id,
        preferred_username,
        inbox,
        outbox,
        name: name,
        summary: summary,
        followers: followers,
        following: following,
        shared_inbox: shared_inbox,
        public_key: public_key,
        assertion_methods: assertion_methods,
        gateways: gateways
      )
    end

    # Build a subscription `Follow` for a relay client.
    #
    # * `Protocol::Mastodon` targets the public collection.
    # * `Protocol::LitePub` targets the relay actor URI.
    #
    # Either way the activity is addressed to the relay so it reaches the relay
    # inbox.
    def self.subscribe(id : String, actor : String, relay : String, protocol : Protocol = Protocol::Mastodon) : JsonMap
      object = protocol.lite_pub? ? relay : PUBLIC_COLLECTION
      Aptok.follow(id, actor, object, to: [relay])
    end

    # Build an unsubscription `Undo` wrapping the original `Follow` (embedded
    # object or bare URI). When `relay` is omitted it is inferred from an
    # embedded follow.
    def self.unsubscribe(id : String, actor : String, follow : JsonMap | String, relay : String? = nil) : JsonMap
      target = relay || relay_from_follow(follow)
      to = target ? [target] : [] of String
      Aptok.undo(id, actor, follow, to: to)
    end

    # Build a LitePub publish `Announce` referencing the object by URI (or value)
    # and addressed to the relay's followers collection plus an optional admin
    # actor. A `published` timestamp is always present (defaults to now).
    def self.announce(
      id : String,
      actor : String,
      object : JsonMap | String,
      followers : String,
      admin : String? = nil,
      published : String? = nil
    ) : JsonMap
      to = [followers]
      to << admin if admin
      activity = Aptok.announce(id, actor, object, to: to)
      activity["published"] = Aptok.json(published) if published
      activity
    end

    # Build an `Accept` acknowledging a subscription `Follow`, addressed to the
    # subscribing follower.
    def self.accept(id : String, actor : String, follow : JsonMap | String, follower : String) : JsonMap
      Aptok.accept(id, actor, follow, to: [follower])
    end

    # Build a `Reject` declining a subscription `Follow`, addressed to the
    # requesting follower.
    def self.reject(id : String, actor : String, follow : JsonMap | String, follower : String) : JsonMap
      Aptok.reject(id, actor, follow, to: [follower])
    end

    # Build the reciprocal `Follow` a LitePub relay sends back to a subscriber.
    def self.reciprocal_follow(id : String, relay : String, follower : String) : JsonMap
      Aptok.follow(id, relay, follower, to: [follower])
    end

    # The activity's `type`, accepting either a string or an array of strings.
    def self.activity_type(activity : JsonMap) : String?
      type = activity["type"]?
      return nil unless type
      type.as_s? || type.as_a?.try(&.compact_map(&.as_s?).first?)
    end

    # The activity's `actor` id (string id, embedded object id, or first of an
    # array).
    def self.actor_id(activity : JsonMap) : String?
      object_uri(activity["actor"]?)
    end

    # The subscribing actor of a `Follow`.
    def self.follower(activity : JsonMap) : String?
      return nil unless activity_type(activity) == "Follow"
      actor_id(activity)
    end

    # The unsubscribing actor of an `Undo`/`Follow`.
    def self.unfollower(activity : JsonMap) : String?
      return nil unless unsubscription?(activity)
      actor_id(activity)
    end

    # Whether the activity is a subscription `Follow` for `relay`.
    def self.subscription?(activity : JsonMap, relay : String) : Bool
      !subscription_protocol(activity, relay).nil?
    end

    # Classify a subscription `Follow` as Mastodon-style (object is the public
    # collection) or LitePub-style (object is the relay actor). Returns nil when
    # the activity is not a relay subscription.
    def self.subscription_protocol(activity : JsonMap, relay : String) : Protocol?
      return nil unless activity_type(activity) == "Follow"
      object = object_uri(activity["object"]?)
      return nil unless object
      return Protocol::Mastodon if object == PUBLIC_COLLECTION
      return Protocol::LitePub if Aptok.same_resource_id?(object, relay)
      nil
    end

    # Whether the activity is an `Undo` of a `Follow` (embedded follow object or
    # a bare follow URI).
    def self.unsubscription?(activity : JsonMap) : Bool
      return false unless activity_type(activity) == "Undo"
      inner = activity["object"]?
      return false unless inner
      if map = inner.as_h?
        return map["type"]?.try(&.as_s?) == "Follow"
      end
      !!inner.as_s?
    end

    # Whether the activity is one that a relay forwards to its followers.
    def self.relayable?(activity : JsonMap) : Bool
      type = activity_type(activity)
      !!type && RELAYABLE_ACTIVITY_TYPES.includes?(type)
    end

    # Filter `recipients` down to fan-out targets, excluding every recipient
    # that matches one of `origins` (the publishing actor and/or verified
    # sender) and de-duplicating by delivery inbox.
    #
    # A relay MUST NOT send an activity back to the actor it originated from
    # (FEP-ae0c). Matching is FEP-ef61 aware via `Aptok.same_resource_id?`.
    def self.fanout_recipients(recipients : Array(Recipient), origins : Array(String)) : Array(Recipient)
      seen = Set(String).new
      result = [] of Recipient
      recipients.each do |recipient|
        next if origins.any? { |origin| excludes_recipient?(recipient, origin) }
        next if seen.includes?(recipient.inbox)
        seen << recipient.inbox
        result << recipient
      end
      result
    end

    # :ditto:
    def self.fanout_recipients(recipients : Array(Recipient), origin : String) : Array(Recipient)
      fanout_recipients(recipients, [origin])
    end

    # Resolve a string id from a JSON value that may be a string, an object with
    # `id`/`@id`, or an array of either.
    def self.object_uri(value : JSON::Any?) : String?
      return nil unless value
      if str = value.as_s?
        return str
      end
      if map = value.as_h?
        return map["id"]?.try(&.as_s?) || map["@id"]?.try(&.as_s?)
      end
      if arr = value.as_a?
        arr.each do |item|
          if found = object_uri(item)
            return found
          end
        end
      end
      nil
    end

    private def self.relay_from_follow(follow : JsonMap | String) : String?
      return nil if follow.is_a?(String)
      object_uri(follow["object"]?) || object_uri(follow["to"]?)
    end

    private def self.excludes_recipient?(recipient : Recipient, origin : String) : Bool
      return true if Aptok.same_resource_id?(recipient.id, origin)
      return true if recipient.actor_ids.any? { |actor_id| Aptok.same_resource_id?(actor_id, origin) }
      return true if recipient.inbox == origin
      if shared = recipient.shared_inbox
        return true if shared == origin
      end
      false
    end
  end
end
