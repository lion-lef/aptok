require "random/secure"
require "../federation/federation_context"

module Aptok
  module Relay
    # Outcome of handling an inbound relay activity.
    enum Outcome
      # A subscription was registered.
      Subscribed
      # A subscription was removed.
      Unsubscribed
      # The activity was not a relay control activity (or was a no-op).
      Ignored
      # A subscription `Follow` could not be resolved to a deliverable actor.
      Unresolvable
    end

    # Result of `Server#handle`, `Server#subscribe` and `Server#unsubscribe`.
    record HandleResult,
      outcome : Outcome,
      protocol : Protocol? = nil,
      actor : String? = nil,
      sent : Array(SentActivity) = [] of SentActivity do
      def subscribed? : Bool
        outcome.subscribed?
      end

      def unsubscribed? : Bool
        outcome.unsubscribed?
      end

      # Whether a subscription was added or removed.
      def handled? : Bool
        outcome.subscribed? || outcome.unsubscribed?
      end
    end

    # Orchestrates a relay server actor: processes inbound `Follow`/`Undo`
    # control activities, tracks subscribers in a `Subscriptions` registry, and
    # fans relayed content out to followers.
    #
    # Works for both classic `https://` and FEP-ef61 portable `ap://` relay and
    # client actors. Subscriber inboxes that are portable `ap://` URIs are
    # resolved to gateway delivery URLs automatically by `recipient_from_actor`,
    # and origin exclusion is performed with `Aptok.same_resource_id?`, so no
    # special-casing is required for portable actors.
    #
    # Content is forwarded *unchanged* via `Context#send_activity`, which
    # preserves any existing LD signature (`RsaSignature2017`) on the activity
    # and adds the relay's own HTTP Signature — exactly the FEP-ae0c relaying
    # behaviour, with no need for the relay to generate LD signatures itself.
    class Server
      getter relay_id : String
      getter sender_identifier : String
      getter subscriptions : Subscriptions

      def initialize(@relay_id : String, @sender_identifier : String, @subscriptions : Subscriptions)
      end

      # Handle an inbound activity delivered to the relay actor's inbox.
      #
      # A subscription `Follow` triggers follower resolution (preferring an
      # embedded actor object, otherwise `ctx.lookup_object`), registration and
      # an `Accept` (plus a reciprocal `Follow` for LitePub). An `Undo`/`Follow`
      # removes the subscriber. Anything else is ignored.
      def handle(ctx : Context, activity : JsonMap, options : LookupObjectOptions = LookupObjectOptions.new) : HandleResult
        case Relay.activity_type(activity)
        when "Follow"
          handle_follow(ctx, activity, options)
        when "Undo"
          handle_undo(activity)
        else
          HandleResult.new(Outcome::Ignored)
        end
      end

      # Register a subscriber from a resolved actor document and send the
      # protocol's acknowledgement (`Accept`, plus a reciprocal `Follow` for
      # LitePub). Returns an `Unresolvable` result when the actor lacks an inbox.
      def subscribe(ctx : Context, follower_actor : JsonMap, follow : JsonMap, protocol : Protocol) : HandleResult
        recipient = @subscriptions.add(follower_actor)
        unless recipient
          return HandleResult.new(Outcome::Unresolvable, protocol, Relay.actor_id(follow))
        end

        sent = [] of SentActivity
        accept = Relay.accept(new_activity_id, @relay_id, follow, recipient.id)
        sent.concat(ctx.send_activity(@sender_identifier, [recipient], accept))
        if protocol.lite_pub?
          reciprocal = Relay.reciprocal_follow(new_activity_id, @relay_id, recipient.id)
          sent.concat(ctx.send_activity(@sender_identifier, [recipient], reciprocal))
        end
        HandleResult.new(Outcome::Subscribed, protocol, recipient.id, sent)
      end

      # Remove a subscriber by actor id.
      def unsubscribe(actor_id : String) : HandleResult
        removed = @subscriptions.remove(actor_id)
        HandleResult.new(removed ? Outcome::Unsubscribed : Outcome::Ignored, nil, actor_id)
      end

      # Fan a relayed activity out to every subscriber except its origin.
      #
      # `origins` defaults to the activity's own `actor`; pass the verified
      # sending actor (e.g. the HTTP Signature key owner) when it differs from
      # the embedded `actor` so the relay never echoes content back to its
      # source. The activity is forwarded unchanged. Returns the activities
      # actually delivered (empty when not relayable, already relayed, or there
      # are no eligible followers).
      def relay(
        ctx : Context,
        activity : JsonMap,
        origins : Array(String) = [] of String,
        *,
        dedupe : Bool = true,
        relayable_only : Bool = true
      ) : Array(SentActivity)
        return [] of SentActivity if relayable_only && !Relay.relayable?(activity)

        activity_id = activity["id"]?.try(&.as_s?)
        return [] of SentActivity if dedupe && activity_id && @subscriptions.relayed?(activity_id)

        all_origins = origins.dup
        if all_origins.empty? && (origin = Relay.actor_id(activity))
          all_origins << origin
        end

        targets = Relay.fanout_recipients(@subscriptions.recipients, all_origins)
        return [] of SentActivity if targets.empty?

        sent = ctx.send_activity(@sender_identifier, targets, activity)
        @subscriptions.mark_relayed(activity_id) if dedupe && activity_id
        sent
      end

      private def handle_follow(ctx : Context, activity : JsonMap, options : LookupObjectOptions) : HandleResult
        protocol = Relay.subscription_protocol(activity, @relay_id)
        return HandleResult.new(Outcome::Ignored) unless protocol

        follower = Relay.follower(activity)
        return HandleResult.new(Outcome::Ignored) unless follower

        actor = resolve_actor(ctx, follower, activity, options)
        return HandleResult.new(Outcome::Unresolvable, protocol, follower) unless actor

        subscribe(ctx, actor, activity, protocol)
      end

      private def handle_undo(activity : JsonMap) : HandleResult
        actor = Relay.unfollower(activity)
        return HandleResult.new(Outcome::Ignored) unless actor

        unsubscribe(actor)
      end

      # Resolve the follower's actor document. Prefer an actor object embedded in
      # the `Follow` (when it carries an inbox); otherwise look it up remotely
      # (gateway-aware for portable URIs).
      private def resolve_actor(ctx : Context, follower : String, activity : JsonMap, options : LookupObjectOptions) : JsonMap?
        if embedded = activity["actor"]?.try(&.as_h?)
          return embedded if embedded["inbox"]?
        end
        ctx.lookup_object(follower, options)
      rescue
        nil
      end

      private def new_activity_id : String
        "#{@relay_id}/activities/#{Random::Secure.hex(16)}"
      end
    end
  end
end
