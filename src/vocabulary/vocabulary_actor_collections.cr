module Aptok
  module Vocab
    class Commit < ForgeFedObject
      getter hash : String?
      getter attributed_to : String?
      getter summary : String?
      getter created : String?
      getter committed_by : String?
      getter committed : String?
      getter description : String?
      getter files_added : Array(String)
      getter files_modified : Array(String)
      getter files_removed : Array(String)

      def self.from_json_ld(value : JSON::Any) : Commit
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Commit
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @hash = self.class.string_property(json, "hash")
        @attributed_to = self.class.string_property(json, "attributedTo")
        @summary = self.class.string_property(json, "summary")
        @created = self.class.string_property(json, "created")
        @committed_by = self.class.string_property(json, "committedBy")
        @committed = self.class.string_property(json, "committed")
        @description = self.class.string_property(json, "description") || json["description"]?.try(&.as_h?).try { |description| description["content"]?.try(&.as_s?) }
        @files_added = self.class.string_array_property(json, "filesAdded")
        @files_modified = self.class.string_array_property(json, "filesModified")
        @files_removed = self.class.string_array_property(json, "filesRemoved")
      end
    end
  end
end
