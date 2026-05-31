module Aptok
  def self.valid_forgefed?(document : JsonMap) : Bool
    forgefed_validation_errors(document).empty?
  end

  def self.validate_forgefed!(document : JsonMap) : JsonMap
    errors = forgefed_validation_errors(document)
    raise ArgumentError.new("invalid ForgeFed document: #{errors.join(", ")}") unless errors.empty?

    document
  end

  def self.forgefed_validation_errors(document : JsonMap) : Array(String)
    errors = [] of String
    type = validation_type(document)
    unless type
      errors << "type is required"
      return errors
    end
    unless FORGEFED_TYPES.includes?(type) || FORGEFED_ACTIVITY_TYPES.includes?(type)
      errors << "unsupported ForgeFed type: #{type}"
      return errors
    end

    require_context(document, FORGEFED_CONTEXT, errors)
    case type
    when "Repository"
      require_string_property(document, "id", errors)
      require_string_property(document, "name", errors)
      require_string_property(document, "inbox", errors)
      require_string_property(document, "outbox", errors)
      validate_optional_string_array_property(document, "pushUri", errors)
      validate_optional_bool_property(document, "isArchived", errors)
    when "Project"
      require_string_property(document, "id", errors)
      require_string_property(document, "name", errors)
      validate_optional_string_property(document, "inbox", errors)
      validate_optional_string_property(document, "outbox", errors)
      validate_optional_string_property(document, "followers", errors)
    when "Branch"
      require_string_property(document, "id", errors)
      require_string_property(document, "context", errors)
      require_string_property(document, "name", errors)
      require_string_property(document, "ref", errors)
    when "Commit"
      require_string_property(document, "id", errors)
      require_string_property(document, "context", errors)
      require_string_property(document, "hash", errors)
      require_string_property(document, "attributedTo", errors)
      require_string_property(document, "summary", errors)
      require_string_property(document, "created", errors)
      validate_optional_string_property(document, "committedBy", errors)
      validate_optional_string_property(document, "committed", errors)
      validate_optional_commit_description(document, errors)
      validate_optional_string_array_property(document, "filesAdded", errors)
      validate_optional_string_array_property(document, "filesModified", errors)
      validate_optional_string_array_property(document, "filesRemoved", errors)
    when "Push"
      require_string_property(document, "id", errors)
      require_string_property(document, "actor", errors)
      require_string_property(document, "attributedTo", errors)
      require_string_property(document, "context", errors)
      require_object_or_link_property(document, "target", errors)
      require_string_property(document, "hashBefore", errors)
      require_string_property(document, "hashAfter", errors)
      validate_collection_property(document, "object", errors)
      validate_string_array_property(document, "to", errors, require_nonempty: true)
      require_string_property(document, "published", errors)
    when "Ticket", "MergeRequest"
      require_string_property(document, "id", errors)
      require_string_property(document, "name", errors)
      require_string_property(document, "content", errors)
      validate_optional_string_property(document, "assignee", errors)
      validate_optional_string_property(document, "attributedTo", errors)
      validate_optional_string_property(document, "context", errors)
      validate_optional_bool_property(document, "resolved", errors)
      validate_optional_object_or_link_array_property(document, "attachment", errors)
      validate_optional_object_or_link_array_property(document, "dependsOn", errors)
      validate_optional_object_or_link_array_property(document, "dependants", errors)
      validate_optional_string_property(document, "mrDiff", errors)
    when "TicketDependency"
      validate_optional_string_property(document, "id", errors)
      validate_optional_string_property(document, "attributedTo", errors)
      validate_optional_string_property(document, "summary", errors)
      validate_optional_string_property(document, "published", errors)
      require_object_or_link_property(document, "subject", errors)
      require_object_or_link_property(document, "object", errors)
      relationship = validation_string_property(document, "relationship")
      if relationship.nil? || relationship.empty?
        errors << "relationship is required"
      elsif relationship != "dependsOn"
        errors << "relationship must be dependsOn"
      end
    when "Tag"
      require_string_property(document, "id", errors)
      require_string_property(document, "name", errors)
      validate_optional_string_property(document, "context", errors)
      validate_optional_string_property(document, "href", errors)
    when "TicketTracker", "PatchTracker"
      require_string_property(document, "id", errors)
      require_string_property(document, "name", errors)
      validate_optional_string_property(document, "context", errors)
      validate_optional_string_property(document, "inbox", errors)
      validate_optional_string_property(document, "outbox", errors)
    when "Resolve", "Apply", "Grant", "Revoke"
      require_string_property(document, "id", errors)
      require_string_property(document, "actor", errors)
      require_object_or_link_property(document, "object", errors)
      validate_optional_object_or_link_property(document, "target", errors)
      validate_string_array_property(document, "to", errors, require_nonempty: true) if document.has_key?("to")
      validate_optional_string_property(document, "published", errors)
    end

    errors
  end

  def self.valid_fep_0837?(document : JsonMap) : Bool
    fep_0837_validation_errors(document).empty?
  end

  def self.validate_fep_0837!(document : JsonMap) : JsonMap
    errors = fep_0837_validation_errors(document)
    raise ArgumentError.new("invalid FEP-0837 document: #{errors.join(", ")}") unless errors.empty?

    document
  end

  def self.fep_0837_validation_errors(document : JsonMap) : Array(String)
    errors = [] of String
    type = validation_type(document)
    unless type
      errors << "type is required"
      return errors
    end
    unless MARKETPLACE_TYPES.includes?(type)
      errors << "unsupported FEP-0837 type: #{type}"
      return errors
    end

    if document.has_key?("@context") && !fep_0837_context?(document)
      errors << "@context must include #{MARKETPLACE_CONTEXT} or #{VALUEFLOWS_CONTEXT}"
    end
    validate_fep_0837_document(document, errors)
    errors
  end

  private def self.validate_fep_0837_document(document : JsonMap, errors : Array(String), path : String = "")
    type = validation_type(document)
    case type
    when "Offer"
      validate_fep_0837_offer(document, errors, path)
    when "Product"
      validate_fep_0837_named_object(document, errors, path)
    when "Service"
      validate_fep_0837_named_object(document, errors, path)
      validate_optional_object_or_link_property(document, "provider", errors, prefixed(path, "provider"))
      validate_optional_string_property(document, "termsOfService", errors, prefixed(path, "termsOfService"))
    when "Listing"
      validate_fep_0837_listing(document, errors, path)
    when "PriceSpecification"
      require_string_property(document, "price", errors, prefixed(path, "price"))
      require_string_property(document, "priceCurrency", errors, prefixed(path, "priceCurrency"))
      validate_optional_string_property(document, "unitText", errors, prefixed(path, "unitText"))
    when "Intent"
      require_string_property(document, "id", errors, prefixed(path, "id"))
      require_string_property(document, "action", errors, prefixed(path, "action"))
      validate_required_measure_property(document, "resourceQuantity", errors, prefixed(path, "resourceQuantity"))
      validate_optional_measure_property(document, "availableQuantity", errors, prefixed(path, "availableQuantity"))
      validate_optional_measure_property(document, "minimumQuantity", errors, prefixed(path, "minimumQuantity"))
      validate_optional_string_property(document, "resourceConformsTo", errors, prefixed(path, "resourceConformsTo"))
    when "Proposal"
      validate_fep_0837_proposal(document, errors, path)
    when "Commitment"
      require_string_property(document, "satisfies", errors, prefixed(path, "satisfies"))
      validate_required_measure_property(document, "resourceQuantity", errors, prefixed(path, "resourceQuantity"))
    when "Agreement"
      validate_required_fep_0837_object(document, "stipulates", "Commitment", errors, prefixed(path, "stipulates"))
      validate_optional_fep_0837_object(document, "stipulatesReciprocal", "Commitment", errors, prefixed(path, "stipulatesReciprocal"))
      validate_optional_string_property(document, "id", errors, prefixed(path, "id"))
      validate_optional_string_property(document, "attributedTo", errors, prefixed(path, "attributedTo"))
    when "Measure"
      validate_measure(document, errors, path.empty? ? "measure" : path)
    end
  end

  private def self.validate_fep_0837_named_object(document : JsonMap, errors : Array(String), path : String)
    require_string_property(document, "id", errors, prefixed(path, "id"))
    require_string_property(document, "name", errors, prefixed(path, "name"))
    validate_optional_string_property(document, "summary", errors, prefixed(path, "summary"))
    validate_optional_string_property(document, "attributedTo", errors, prefixed(path, "attributedTo"))
  end

  private def self.validate_fep_0837_offer(document : JsonMap, errors : Array(String), path : String)
    require_string_property(document, "id", errors, prefixed(path, "id"))
    require_string_property(document, "actor", errors, prefixed(path, "actor"))
    unless document.has_key?("item") || document.has_key?("object")
      errors << "#{prefixed(path, "item")} or #{prefixed(path, "object")} is required"
    end
    validate_optional_object_or_link_property(document, "item", errors, prefixed(path, "item"))
    validate_optional_object_or_link_property(document, "object", errors, prefixed(path, "object"))
    validate_optional_string_property(document, "name", errors, prefixed(path, "name"))
    validate_optional_string_property(document, "price", errors, prefixed(path, "price"))
    validate_optional_string_property(document, "priceCurrency", errors, prefixed(path, "priceCurrency"))
    validate_string_array_property(document, "to", errors, prefixed(path, "to"), require_nonempty: true) if document.has_key?("to")
  end

  private def self.validate_fep_0837_listing(document : JsonMap, errors : Array(String), path : String)
    require_string_property(document, "id", errors, prefixed(path, "id"))
    require_string_property(document, "actor", errors, prefixed(path, "actor"))
    require_string_property(document, "name", errors, prefixed(path, "name"))
    require_object_or_link_property(document, "item", errors, prefixed(path, "item"))
    validate_optional_object_or_link_property(document, "priceSpecification", errors, prefixed(path, "priceSpecification"))
    validate_string_array_property(document, "to", errors, prefixed(path, "to"), require_nonempty: true)
  end

  private def self.validate_fep_0837_proposal(document : JsonMap, errors : Array(String), path : String)
    require_string_property(document, "id", errors, prefixed(path, "id"))
    require_string_property(document, "purpose", errors, prefixed(path, "purpose"))
    require_string_property(document, "attributedTo", errors, prefixed(path, "attributedTo"))
    validate_required_fep_0837_object(document, "publishes", "Intent", errors, prefixed(path, "publishes"))
    validate_optional_fep_0837_object(document, "reciprocal", "Intent", errors, prefixed(path, "reciprocal"))
    validate_optional_bool_property(document, "unitBased", errors, prefixed(path, "unitBased"))
    validate_string_array_property(document, "to", errors, prefixed(path, "to"), require_nonempty: true)
    validate_optional_object_or_link_property(document, "location", errors, prefixed(path, "location"))
  end

  private def self.validate_required_fep_0837_object(
    document : JsonMap,
    key : String,
    expected_type : String,
    errors : Array(String),
    path : String
  )
    value = document[key]?
    unless value
      errors << "#{path} is required"
      return
    end
    validate_fep_0837_object(value, expected_type, errors, path)
  end

  private def self.validate_optional_fep_0837_object(
    document : JsonMap,
    key : String,
    expected_type : String,
    errors : Array(String),
    path : String
  )
    value = document[key]?
    validate_fep_0837_object(value, expected_type, errors, path) if value
  end

  private def self.validate_fep_0837_object(
    value : JSON::Any,
    expected_type : String,
    errors : Array(String),
    path : String
  )
    object = value.as_h?
    unless object
      errors << "#{path} must be an object"
      return
    end
    map = object.as(JsonMap)
    actual_type = validation_type(map)
    unless actual_type == expected_type
      errors << "#{path}.type must be #{expected_type}"
      return
    end
    validate_fep_0837_document(map, errors, path)
  end

  private def self.validate_required_measure_property(document : JsonMap, key : String, errors : Array(String), path : String)
    value = document[key]?
    unless value
      errors << "#{path} is required"
      return
    end
    validate_measure_value(value, errors, path)
  end

  private def self.validate_optional_measure_property(document : JsonMap, key : String, errors : Array(String), path : String)
    value = document[key]?
    validate_measure_value(value, errors, path) if value
  end

  private def self.validate_measure_value(value : JSON::Any, errors : Array(String), path : String)
    object = value.as_h?
    unless object
      errors << "#{path} must be an object"
      return
    end
    validate_measure(object.as(JsonMap), errors, path)
  end

  private def self.validate_measure(document : JsonMap, errors : Array(String), path : String)
    require_string_property(document, "hasUnit", errors, prefixed(path, "hasUnit"))
    validate_optional_string_property(document, "hasNumericalValue", errors, prefixed(path, "hasNumericalValue"))
  end

  private def self.require_context(document : JsonMap, context : String, errors : Array(String))
    errors << "@context must include #{context}" unless validation_context_includes?(document, context)
  end

  private def self.validation_type(document : JsonMap) : String?
    names = validation_type_names(document)
    names.find do |type|
      FORGEFED_TYPES.includes?(type) ||
        FORGEFED_ACTIVITY_TYPES.includes?(type) ||
        MARKETPLACE_TYPES.includes?(type)
    end || names.first?
  end

  private def self.validation_type_names(document : JsonMap) : Array(String)
    property = document["type"]?
    return [] of String unless property

    if string = property.as_s?
      [type_name(string)]
    else
      property.as_a?.try(&.compact_map { |item| item.as_s?.try { |type| type_name(type) } }) || [] of String
    end
  end

  private def self.validation_string_property(document : JsonMap, key : String) : String?
    property = document[key]?
    return nil unless property

    if string = property.as_s?
      string
    elsif array = property.as_a?
      array.compact_map(&.as_s?).first?
    end
  end

  private def self.require_string_property(document : JsonMap, key : String, errors : Array(String))
    require_string_property(document, key, errors, key)
  end

  private def self.require_string_property(document : JsonMap, key : String, errors : Array(String), path : String)
    value = validation_string_property(document, key)
    errors << "#{path} is required" if value.nil? || value.empty?
  end

  private def self.validate_optional_string_property(document : JsonMap, key : String, errors : Array(String))
    validate_optional_string_property(document, key, errors, key)
  end

  private def self.validate_optional_string_property(document : JsonMap, key : String, errors : Array(String), path : String)
    return unless document.has_key?(key)

    value = validation_string_property(document, key)
    errors << "#{path} must be a string" if value.nil?
  end

  private def self.validate_optional_bool_property(document : JsonMap, key : String, errors : Array(String))
    validate_optional_bool_property(document, key, errors, key)
  end

  private def self.validate_optional_bool_property(document : JsonMap, key : String, errors : Array(String), path : String)
    return unless document.has_key?(key)

    errors << "#{path} must be a boolean" if document[key]?.try(&.as_bool?).nil?
  end

  private def self.validate_optional_commit_description(document : JsonMap, errors : Array(String))
    property = document["description"]?
    return unless property
    return if property.as_s?

    object = property.as_h?
    unless object
      errors << "description must be a string or object"
      return
    end
    content = object["content"]?.try(&.as_s?)
    errors << "description.content must be a string" unless content
  end

  private def self.validate_optional_string_array_property(document : JsonMap, key : String, errors : Array(String))
    validate_string_array_property(document, key, errors) if document.has_key?(key)
  end

  private def self.validate_string_array_property(
    document : JsonMap,
    key : String,
    errors : Array(String),
    path : String? = nil,
    require_nonempty : Bool = false
  )
    property = document[key]?
    label = path || key
    unless property
      errors << "#{label} is required" if require_nonempty
      return
    end

    if string = property.as_s?
      errors << "#{label} must not be empty" if require_nonempty && string.empty?
    elsif array = property.as_a?
      errors << "#{label} must not be empty" if require_nonempty && array.empty?
      array.each_with_index do |item, index|
        errors << "#{label}[#{index}] must be a string" unless item.as_s?
      end
    else
      errors << "#{label} must be a string or array of strings"
    end
  end

  private def self.require_object_or_link_property(document : JsonMap, key : String, errors : Array(String))
    require_object_or_link_property(document, key, errors, key)
  end

  private def self.require_object_or_link_property(document : JsonMap, key : String, errors : Array(String), path : String)
    property = document[key]?
    unless property
      errors << "#{path} is required"
      return
    end
    validate_object_or_link_value(property, errors, path)
  end

  private def self.validate_optional_object_or_link_property(document : JsonMap, key : String, errors : Array(String))
    validate_optional_object_or_link_property(document, key, errors, key)
  end

  private def self.validate_optional_object_or_link_property(document : JsonMap, key : String, errors : Array(String), path : String)
    property = document[key]?
    validate_object_or_link_value(property, errors, path) if property
  end

  private def self.validate_optional_object_or_link_array_property(document : JsonMap, key : String, errors : Array(String))
    property = document[key]?
    return unless property

    if array = property.as_a?
      array.each_with_index { |item, index| validate_object_or_link_value(item, errors, "#{key}[#{index}]") }
    else
      validate_object_or_link_value(property, errors, key)
    end
  end

  private def self.validate_object_or_link_value(value : JSON::Any, errors : Array(String), path : String)
    if string = value.as_s?
      errors << "#{path} must not be empty" if string.empty?
    elsif value.as_h?
      nil
    else
      errors << "#{path} must be an object or string"
    end
  end

  private def self.validate_collection_property(document : JsonMap, key : String, errors : Array(String))
    property = document[key]?
    unless property
      errors << "#{key} is required"
      return
    end
    object = property.as_h?
    unless object
      errors << "#{key} must be a Collection or OrderedCollection object"
      return
    end
    map = object.as(JsonMap)
    type = validation_type(map)
    unless type.in?("Collection", "OrderedCollection")
      errors << "#{key}.type must be Collection or OrderedCollection"
      return
    end
    items_key = type == "OrderedCollection" ? "orderedItems" : "items"
    items = map[items_key]?
    errors << "#{key}.#{items_key} must be an array" if items && items.as_a?.nil?
  end

  private def self.validation_context_includes?(document : JsonMap, context : String) : Bool
    property = document["@context"]?
    return false unless property

    if string = property.as_s?
      string == context
    elsif array = property.as_a?
      array.any? do |item|
        item.as_s? == context ||
          item.as_h?.try(&.values.any? { |value| value.as_s? == context }) ||
          false
      end
    elsif object = property.as_h?
      object.values.any? { |value| value.as_s? == context }
    else
      false
    end
  end

  private def self.fep_0837_context?(document : JsonMap) : Bool
    validation_context_includes?(document, MARKETPLACE_CONTEXT) ||
      validation_context_includes?(document, VALUEFLOWS_CONTEXT)
  end

  private def self.prefixed(prefix : String, key : String) : String
    prefix.empty? ? key : "#{prefix}.#{key}"
  end
end
