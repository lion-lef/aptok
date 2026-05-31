module Aptok
  module Vocab
    activity_type Accept, Activity
    activity_type Add, Activity
    activity_type Announce, Activity
    activity_type IntransitiveActivity, Activity
    activity_type Delete, Activity
    activity_type Dislike, Activity
    activity_type Flag, Activity
    activity_type Follow, Activity
    activity_type Ignore, Activity
    activity_type Join, Activity
    activity_type Leave, Activity
    activity_type Like, Activity
    activity_type Listen, Activity
    activity_type Move, Activity
    activity_type ActivityOffer, Activity
    activity_type Reject, Activity
    activity_type Read, Activity
    activity_type Remove, Activity
    activity_type Arrive, IntransitiveActivity
    activity_type Travel, IntransitiveActivity
    activity_type Undo, Activity
    activity_type Update, Activity
    activity_type View, Activity

    activity_type Invite, ActivityOffer
    activity_type TentativeAccept, Accept
    activity_type TentativeReject, Reject
    activity_type Block, Ignore

    class ForgeFedActivity < Activity
      def self.from_json_ld(value : JSON::Any) : ForgeFedActivity
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : ForgeFedActivity
        new(value)
      end
    end

    activity_type Resolve, ForgeFedActivity
    activity_type Apply, ForgeFedActivity
    activity_type Grant, ForgeFedActivity
    activity_type Revoke, ForgeFedActivity

    class ActivityOffer < Activity
      def self.type_name : String
        "Offer"
      end
    end

    class Question < IntransitiveActivity
      getter one_of : Array(Object | String)
      getter any_of : Array(Object | String)
      getter closed : String?
      getter end_time : String?
      getter voters_count : Int32?

      def self.from_json_ld(value : JSON::Any) : Question
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Question
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @one_of = self.class.object_array_property(json, "oneOf")
        @any_of = self.class.object_array_property(json, "anyOf")
        @closed = self.class.closed_property(json)
        @end_time = self.class.string_property(json, "endTime")
        @voters_count = self.class.int_property(json, "votersCount")
      end

      protected def self.closed_property(value : JsonMap) : String?
        property = value["closed"]?
        return nil unless property

        property.as_s? || property.as_bool?.try(&.to_s)
      end
    end

    class StandardObject < Object
      getter name : String?
      getter summary : String?
      getter content : String?
      getter media_type : String?
      getter url : Object | String | Nil
      getter previews : Array(Object | String)
      getter attributed_to : Array(Object | String)
      getter attachment : Array(Object | String)
      getter tags : Array(Object | String)
      getter published : String?
      getter updated : String?
      getter start_time : String?
      getter end_time : String?
      getter duration : String?
      getter source : Source?
      getter proofs : Array(Object | String)
      getter replies : Object | String | Nil
      getter shares : Object | String | Nil
      getter likes : Object | String | Nil
      getter emoji_reactions : Object | String | Nil
      getter sensitive : Bool?
      getter quote : Object | String | Nil
      getter quote_url : String?
      getter quote_authorization : Object | String | Nil

      def initialize(json : JsonMap)
        super(json)
        @name = self.class.string_property(json, "name")
        @summary = self.class.string_property(json, "summary")
        @content = self.class.string_property(json, "content")
        @media_type = self.class.string_property(json, "mediaType")
        @url = self.class.object_property(json, "url")
        @previews = self.class.object_array_property(json, "preview")
        @previews = self.class.object_array_property(json, "previews") if @previews.empty?
        @attributed_to = self.class.object_array_property(json, "attributedTo")
        @attachment = self.class.object_array_property(json, "attachment")
        @tags = self.class.object_array_property(json, "tag")
        @published = self.class.string_property(json, "published")
        @updated = self.class.string_property(json, "updated")
        @start_time = self.class.string_property(json, "startTime")
        @end_time = self.class.string_property(json, "endTime")
        @duration = self.class.string_property(json, "duration")
        @source = self.class.source_property(json, "source")
        @proofs = self.class.object_array_property(json, "proof")
        @proofs = self.class.object_array_property(json, "proofs") if @proofs.empty?
        @replies = self.class.object_property(json, "replies")
        @shares = self.class.object_property(json, "shares")
        @likes = self.class.object_property(json, "likes")
        @emoji_reactions = self.class.object_property(json, "emojiReactions")
        @sensitive = self.class.bool_property(json, "sensitive")
        @quote = self.class.object_property(json, "quote") || self.class.object_property(json, "_misskey_quote")
        @quote_url = self.class.string_property(json, "quoteUrl") || self.class.string_property(json, "quoteUri")
        @quote_authorization = self.class.object_property(json, "quoteAuthorization")
      end

      protected def self.source_property(value : JsonMap, key : String) : Source?
        map_property(value, key).try { |source| Source.from_json_ld(source) }
      end
    end

    class Source
      getter json : JsonMap
      getter content : String?
      getter media_type : String?

      def self.from_json_ld(value : JSON::Any) : Source
        from_json_ld(value.as_h?.try(&.as(JsonMap)) || raise ArgumentError.new("JSON-LD source must be an object"))
      end

      def self.from_json_ld(value : JsonMap) : Source
        new(value)
      end

      def initialize(@json : JsonMap)
        @content = self.class.string_property(@json, "content")
        @media_type = self.class.string_property(@json, "mediaType")
      end

      def to_json_ld : JsonMap
        @json.dup
      end

      def self.string_property(value : JsonMap, key : String) : String?
        property = value[key]?
        property.try(&.as_s?) || property.try(&.as_a?).try(&.first?.try(&.as_s?))
      end
    end

    macro object_type(name, parent)
      class {{name.id}} < {{parent.id}}
        def self.from_json_ld(value : JSON::Any) : {{name.id}}
          from_json_ld(json_object(value))
        end

        def self.from_json_ld(value : JsonMap) : {{name.id}}
          new(value)
        end
      end
    end

    object_type Article, StandardObject
    object_type Document, StandardObject
    object_type Audio, Document
    object_type Event, StandardObject
    object_type Image, Document
    object_type Page, Document
    object_type Place, StandardObject
    object_type Profile, StandardObject

    class Relationship < StandardObject
      def self.from_json_ld(value : JSON::Any) : Relationship
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Relationship
        return TicketDependency.from_json_ld(value) if type_names(value).includes?("TicketDependency")

        new(value)
      end
    end

    object_type Video, Document
  end
end
