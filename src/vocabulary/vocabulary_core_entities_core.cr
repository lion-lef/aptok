require "./vocabulary_types"
require "json"
require "uri"

module Aptok
  module Vocab
    class Object
      getter id : String?
      getter type : String?
      getter json : JsonMap

      def self.from_json_ld(value : JSON::Any) : Object
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Object
        types = type_names(value)
        return TicketDependency.from_json_ld(value) if types.includes?("TicketDependency")

        type = types.first?
        case type
        when "Create"
          Create.from_json_ld(value)
        when "Accept"
          Accept.from_json_ld(value)
        when "Add"
          Add.from_json_ld(value)
        when "Announce"
          Announce.from_json_ld(value)
        when "Arrive"
          Arrive.from_json_ld(value)
        when "Block"
          Block.from_json_ld(value)
        when "Delete"
          Delete.from_json_ld(value)
        when "Dislike"
          Dislike.from_json_ld(value)
        when "Flag"
          Flag.from_json_ld(value)
        when "Follow"
          Follow.from_json_ld(value)
        when "Ignore"
          Ignore.from_json_ld(value)
        when "IntransitiveActivity"
          IntransitiveActivity.from_json_ld(value)
        when "Invite"
          Invite.from_json_ld(value)
        when "Join"
          Join.from_json_ld(value)
        when "Leave"
          Leave.from_json_ld(value)
        when "Like"
          Like.from_json_ld(value)
        when "Listen"
          Listen.from_json_ld(value)
        when "Move"
          Move.from_json_ld(value)
        when "Question"
          Question.from_json_ld(value)
        when "Reject"
          Reject.from_json_ld(value)
        when "Read"
          Read.from_json_ld(value)
        when "Remove"
          Remove.from_json_ld(value)
        when "TentativeAccept"
          TentativeAccept.from_json_ld(value)
        when "TentativeReject"
          TentativeReject.from_json_ld(value)
        when "Travel"
          Travel.from_json_ld(value)
        when "Undo"
          Undo.from_json_ld(value)
        when "Update"
          Update.from_json_ld(value)
        when "View"
          View.from_json_ld(value)
        when "Resolve"
          Resolve.from_json_ld(value)
        when "Apply"
          Apply.from_json_ld(value)
        when "Grant"
          Grant.from_json_ld(value)
        when "Revoke"
          Revoke.from_json_ld(value)
        when "Article"
          Article.from_json_ld(value)
        when "Audio"
          Audio.from_json_ld(value)
        when "Document"
          Document.from_json_ld(value)
        when "Event"
          Event.from_json_ld(value)
        when "Image"
          Image.from_json_ld(value)
        when "Note"
          Note.from_json_ld(value)
        when "Page"
          Page.from_json_ld(value)
        when "Place"
          Place.from_json_ld(value)
        when "Profile"
          Profile.from_json_ld(value)
        when "Relationship"
          Relationship.from_json_ld(value)
        when "Tombstone"
          Tombstone.from_json_ld(value)
        when "Video"
          Video.from_json_ld(value)
        when "Link"
          Link.from_json_ld(value)
        when "Mention"
          Mention.from_json_ld(value)
        when "Hashtag"
          Hashtag.from_json_ld(value)
        when "Emoji"
          Emoji.from_json_ld(value)
        when "PropertyValue"
          PropertyValue.from_json_ld(value)
        when "Collection"
          Collection.from_json_ld(value)
        when "OrderedCollection"
          OrderedCollection.from_json_ld(value)
        when "CollectionPage"
          CollectionPage.from_json_ld(value)
        when "OrderedCollectionPage"
          OrderedCollectionPage.from_json_ld(value)
        when "Application", "Group", "Organization", "Person"
          Actor.from_json_ld(value)
        when "Service"
          marketplace_context?(value) ? MarketplaceService.from_json_ld(value) : Actor.from_json_ld(value)
        when "CryptographicKey"
          CryptographicKey.from_json_ld(value)
        when "Multikey"
          Multikey.from_json_ld(value)
        else
          if type
            if MARKETPLACE_TYPES.includes?(type) && marketplace_context?(value)
              MarketplaceObject.from_json_ld(value)
            elsif FORGEFED_TYPES.includes?(type) && forgefed_context?(value)
              ForgeFedObject.from_json_ld(value)
            elsif FORGEFED_ACTIVITY_TYPES.includes?(type) && forgefed_context?(value)
              Activity.from_json_ld(value)
            elsif ACTIVITY_TYPES.includes?(type)
              Activity.from_json_ld(value)
            elsif FORGEFED_TYPES.includes?(type)
              ForgeFedObject.from_json_ld(value)
            elsif FORGEFED_ACTIVITY_TYPES.includes?(type)
              Activity.from_json_ld(value)
            elsif MARKETPLACE_TYPES.includes?(type)
              MarketplaceObject.from_json_ld(value)
            else
              new(value)
            end
          else
            new(value)
          end
        end
      end

      def initialize(@json : JsonMap)
        @id = self.class.string_property(@json, "id")
        @type = self.class.string_property(@json, "type")
      end

      def to_json_ld : JsonMap
        @json.dup
      end

      def to_json(json : JSON::Builder) : Nil
        to_json_ld.to_json(json)
      end

      def self.type_name : String
        name.split("::").last
      end

      def self.type_id : String
        Aptok.type_id(type_name)
      end

      protected def self.json_object(value : JSON::Any) : JsonMap
        value.as_h?
          .try(&.as(JsonMap)) ||
          raise ArgumentError.new("JSON-LD value must be an object")
      end

      protected def self.string_property(value : JsonMap, key : String) : String?
        property = value[key]?
        property.try(&.as_s?) || property.try(&.as_a?).try(&.first?.try(&.as_s?))
      end

      protected def self.type_names(value : JsonMap) : Array(String)
        property = value["type"]?
        return [] of String unless property

        if string = property.as_s?
          [Aptok.type_name(string)]
        else
          property.as_a?.try(&.compact_map { |item| item.as_s?.try { |type| Aptok.type_name(type) } }) || [] of String
        end
      end

      protected def self.string_array_property(value : JsonMap, key : String) : Array(String)
        property = value[key]?
        return [] of String unless property

        if string = property.as_s?
          [string]
        else
          property.as_a?.try(&.compact_map(&.as_s?)) || [] of String
        end
      end

      protected def self.object_property(value : JsonMap, key : String) : Object | String | Nil
        property = value[key]?
        return nil unless property

        if object = property.as_h?
          Object.from_json_ld(object.as(JsonMap))
        else
          property.as_s?
        end
      end

      protected def self.object_array_property(value : JsonMap, key : String) : Array(Object | String)
        property = value[key]?
        return [] of Object | String unless property

        if array = property.as_a?
          array.compact_map do |item|
            if object = item.as_h?
              Object.from_json_ld(object.as(JsonMap)).as(Object | String)
            else
              item.as_s?.try(&.as(Object | String))
            end
          end
        elsif object = property.as_h?
          [Object.from_json_ld(object.as(JsonMap)).as(Object | String)]
        elsif string = property.as_s?
          [string.as(Object | String)]
        else
          [] of Object | String
        end
      end

      protected def self.map_property(value : JsonMap, key : String) : JsonMap?
        value[key]?.try(&.as_h?).try(&.as(JsonMap))
      end

      protected def self.measure_property(value : JsonMap, key : String) : Measure?
        map_property(value, key).try { |measure| Measure.from_json_ld(measure) }
      end

      protected def self.bool_property(value : JsonMap, key : String) : Bool?
        value[key]?.try(&.as_bool?)
      end

      protected def self.int_property(value : JsonMap, key : String) : Int32?
        value[key]?.try(&.as_i?)
      end

      protected def self.context_includes?(value : JsonMap, context : String) : Bool
        property = value["@context"]?
        return false unless property

        if string = property.as_s?
          string == context
        else
          property.as_a?.try(&.any? do |item|
            item.as_s? == context ||
              item.as_h?.try(&.values.any? { |value| value.as_s? == context })
          end) || false
        end
      end

      protected def self.forgefed_context?(value : JsonMap) : Bool
        context_includes?(value, FORGEFED_CONTEXT)
      end

      protected def self.marketplace_context?(value : JsonMap) : Bool
        context_includes?(value, MARKETPLACE_CONTEXT) || context_includes?(value, VALUEFLOWS_CONTEXT)
      end
    end

    class Activity < Object
      getter actor : String?
      getter object : Object | String | Nil
      getter target : Object | String | Nil
      getter result : Object | String | Nil
      getter origin : Object | String | Nil
      getter instrument : Object | String | Nil
      getter to : Array(String)
      getter cc : Array(String)
      getter bto : Array(String)
      getter bcc : Array(String)
      getter audience : Array(String)
      getter published : String?

      def self.from_json_ld(value : JSON::Any) : Activity
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Activity
        type = string_property(value, "type").try { |value| Aptok.type_name(value) }
        case type
        when "Create"
          Create.from_json_ld(value)
        when "Accept"
          Accept.from_json_ld(value)
        when "Add"
          Add.from_json_ld(value)
        when "Announce"
          Announce.from_json_ld(value)
        when "Arrive"
          Arrive.from_json_ld(value)
        when "Block"
          Block.from_json_ld(value)
        when "Delete"
          Delete.from_json_ld(value)
        when "Dislike"
          Dislike.from_json_ld(value)
        when "Flag"
          Flag.from_json_ld(value)
        when "Follow"
          Follow.from_json_ld(value)
        when "Ignore"
          Ignore.from_json_ld(value)
        when "IntransitiveActivity"
          IntransitiveActivity.from_json_ld(value)
        when "Invite"
          Invite.from_json_ld(value)
        when "Join"
          Join.from_json_ld(value)
        when "Leave"
          Leave.from_json_ld(value)
        when "Like"
          Like.from_json_ld(value)
        when "Listen"
          Listen.from_json_ld(value)
        when "Move"
          Move.from_json_ld(value)
        when "Offer"
          ActivityOffer.from_json_ld(value)
        when "Question"
          Question.from_json_ld(value)
        when "Reject"
          Reject.from_json_ld(value)
        when "Read"
          Read.from_json_ld(value)
        when "Remove"
          Remove.from_json_ld(value)
        when "TentativeAccept"
          TentativeAccept.from_json_ld(value)
        when "TentativeReject"
          TentativeReject.from_json_ld(value)
        when "Travel"
          Travel.from_json_ld(value)
        when "Undo"
          Undo.from_json_ld(value)
        when "Update"
          Update.from_json_ld(value)
        when "View"
          View.from_json_ld(value)
        when "Resolve"
          Resolve.from_json_ld(value)
        when "Apply"
          Apply.from_json_ld(value)
        when "Grant"
          Grant.from_json_ld(value)
        when "Revoke"
          Revoke.from_json_ld(value)
        else
          new(value)
        end
      end

      def initialize(json : JsonMap)
        super(json)
        @actor = self.class.string_property(json, "actor")
        @object = self.class.object_property(json, "object")
        @target = self.class.object_property(json, "target")
        @result = self.class.object_property(json, "result")
        @origin = self.class.object_property(json, "origin")
        @instrument = self.class.object_property(json, "instrument")
        @to = self.class.string_array_property(json, "to")
        @cc = self.class.string_array_property(json, "cc")
        @bto = self.class.string_array_property(json, "bto")
        @bcc = self.class.string_array_property(json, "bcc")
        @audience = self.class.string_array_property(json, "audience")
        @published = self.class.string_property(json, "published")
      end
    end

    class Create < Activity
      def self.from_json_ld(value : JSON::Any) : Create
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Create
        new(value)
      end
    end

    macro activity_type(name, parent)
      class {{name.id}} < {{parent.id}}
        def self.from_json_ld(value : JSON::Any) : {{name.id}}
          from_json_ld(json_object(value))
        end

        def self.from_json_ld(value : JsonMap) : {{name.id}}
          new(value)
        end
      end
    end
  end
end
