module Aptok
  module Vocab
    class ForgeFedTag < ForgeFedObject
      getter href : String?

      def self.from_json_ld(value : JSON::Any) : ForgeFedTag
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : ForgeFedTag
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @href = self.class.string_property(json, "href")
      end
    end

    class Tracker < ForgeFedObject
      getter inbox : String?
      getter outbox : String?

      def initialize(json : JsonMap)
        super(json)
        @inbox = self.class.string_property(json, "inbox")
        @outbox = self.class.string_property(json, "outbox")
      end
    end

    class TicketTracker < Tracker
      def self.from_json_ld(value : JSON::Any) : TicketTracker
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : TicketTracker
        new(value)
      end
    end

    class PatchTracker < Tracker
      def self.from_json_ld(value : JSON::Any) : PatchTracker
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : PatchTracker
        new(value)
      end
    end

    class TicketDependency < Relationship
      getter subject : Object | String | Nil
      getter relationship : String?
      getter object : Object | String | Nil

      def self.from_json_ld(value : JSON::Any) : TicketDependency
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : TicketDependency
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @type = "TicketDependency"
        @subject = self.class.object_property(json, "subject")
        @relationship = self.class.string_property(json, "relationship")
        @object = self.class.object_property(json, "object")
      end
    end

    class Push < ForgeFedObject
      getter actor : String?
      getter attributed_to : String?
      getter target : Object | String | Nil
      getter hash_before : String?
      getter hash_after : String?
      getter object : Object | String | Nil
      getter to : Array(String)
      getter published : String?

      def self.from_json_ld(value : JSON::Any) : Push
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Push
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @actor = self.class.string_property(json, "actor")
        @attributed_to = self.class.string_property(json, "attributedTo")
        @target = self.class.object_property(json, "target")
        @hash_before = self.class.string_property(json, "hashBefore")
        @hash_after = self.class.string_property(json, "hashAfter")
        @object = self.class.object_property(json, "object")
        @to = self.class.string_array_property(json, "to")
        @published = self.class.string_property(json, "published")
      end

      def commits : Array(Object | String)
        if collection = @object.as?(OrderedCollection)
          collection.items
        elsif collection = @object.as?(Collection)
          collection.items
        else
          [] of Object | String
        end
      end
    end

    class Ticket < ForgeFedObject
      getter content : String?
      getter assignee : String?
      getter attributed_to : String?
      getter resolved : Bool?
      getter attachments : Array(Object | String)
      getter depends_on : Array(Object | String)
      getter dependants : Array(Object | String)
      getter mr_diff : String?

      def self.from_json_ld(value : JSON::Any) : Ticket
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Ticket
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @content = self.class.string_property(json, "content")
        @assignee = self.class.string_property(json, "assignee")
        @attributed_to = self.class.string_property(json, "attributedTo")
        @resolved = self.class.bool_property(json, "resolved")
        @attachments = self.class.object_array_property(json, "attachment")
        @depends_on = self.class.object_array_property(json, "dependsOn")
        @dependants = self.class.object_array_property(json, "dependants")
        @mr_diff = self.class.string_property(json, "mrDiff")
      end
    end
  end
end
