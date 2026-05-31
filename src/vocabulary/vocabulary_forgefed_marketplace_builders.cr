module Aptok
  def self.marketplace_listing(
    id : String,
    actor : String,
    item : JsonMap,
    name : String,
    price_specification : JsonMap? = nil,
    to : Array(String) = [PUBLIC_COLLECTION]
  ) : JsonMap
    properties = JsonMap{
      "@context" => json([ACTIVITYSTREAMS_CONTEXT, MARKETPLACE_CONTEXT]),
      "actor"    => json(actor),
      "item"     => json(item),
      "name"     => json(name),
      "to"       => json(to),
    }
    properties["priceSpecification"] = json(price_specification) if price_specification
    Aptok.object("Listing", id, properties)
  end

  def self.marketplace_quantity(unit : String = "one", value : String? = nil) : JsonMap
    quantity = JsonMap{"hasUnit" => json(unit)}
    quantity["hasNumericalValue"] = json(value) if value
    quantity
  end

  def self.marketplace_intent(
    id : String,
    action : String,
    quantity : JsonMap,
    resource_conforms_to : String? = nil,
    available_quantity : JsonMap? = nil,
    minimum_quantity : JsonMap? = nil
  ) : JsonMap
    properties = JsonMap{
      "id"               => json(id),
      "type"             => json("Intent"),
      "action"           => json(action),
      "resourceQuantity" => json(quantity),
    }
    properties["resourceConformsTo"] = json(resource_conforms_to) if resource_conforms_to
    properties["availableQuantity"] = json(available_quantity) if available_quantity
    properties["minimumQuantity"] = json(minimum_quantity) if minimum_quantity
    properties
  end

  def self.marketplace_proposal(
    id : String,
    purpose : String,
    attributed_to : String,
    publishes : JsonMap,
    name : String? = nil,
    content : String? = nil,
    reciprocal : JsonMap? = nil,
    unit_based : Bool = false,
    to : Array(String) = [PUBLIC_COLLECTION],
    location : JsonMap? = nil
  ) : JsonMap
    properties = JsonMap{
      "@context"     => marketplace_context,
      "purpose"      => json(purpose),
      "attributedTo" => json(attributed_to),
      "publishes"    => json(publishes),
      "unitBased"    => json(unit_based),
      "to"           => json(to),
      "published"    => json(now),
    }
    properties["name"] = json(name) if name
    properties["content"] = json(content) if content
    properties["reciprocal"] = json(reciprocal) if reciprocal
    properties["location"] = json(location) if location
    Aptok.object("Proposal", id, properties)
  end

  def self.marketplace_payment_link(name : String, proposal_id : String) : JsonMap
    JsonMap{
      "type"      => json("Link"),
      "name"      => json(name),
      "mediaType" => json(FEDERATION_JSONLD_CONTENT_TYPE),
      "href"      => json(proposal_id),
      "rel"       => json(["payment", "#{VALUEFLOWS_CONTEXT}Proposal"]),
    }
  end

  def self.marketplace_commitment(satisfies : String, quantity : JsonMap, id : String? = nil) : JsonMap
    commitment = JsonMap{
      "type"             => json("Commitment"),
      "satisfies"        => json(satisfies),
      "resourceQuantity" => json(quantity),
    }
    commitment["id"] = json(id) if id
    commitment
  end

  def self.marketplace_agreement(
    stipulates : JsonMap,
    id : String? = nil,
    attributed_to : String? = nil,
    reciprocal : JsonMap? = nil
  ) : JsonMap
    agreement = JsonMap{
      "@context"   => marketplace_context,
      "type"       => json("Agreement"),
      "stipulates" => json(stipulates),
    }
    agreement["id"] = json(id) if id
    agreement["attributedTo"] = json(attributed_to) if attributed_to
    agreement["stipulatesReciprocal"] = json(reciprocal) if reciprocal
    agreement
  end

  def self.marketplace_agreement_offer(
    id : String,
    actor : String,
    agreement : JsonMap,
    to : Array(String)
  ) : JsonMap
    properties = JsonMap{
      "@context" => marketplace_context,
      "actor"    => json(actor),
      "object"   => json(agreement),
      "to"       => json(to),
    }
    Aptok.object("Offer", id, properties)
  end

  def self.ordered_collection(id : String, items : Array(JsonMap), total_items : Int32? = nil) : JsonMap
    properties = JsonMap{
      "totalItems"   => json(total_items || items.size),
      "orderedItems" => json(items),
    }
    Aptok.object("OrderedCollection", id, properties)
  end

  def self.collection(id : String, items : Array(JsonMap), total_items : Int32? = nil) : JsonMap
    properties = JsonMap{
      "totalItems" => json(total_items || items.size),
      "items"      => json(items),
    }
    Aptok.object("Collection", id, properties)
  end

  def self.ordered_collection_page(
    id : String,
    part_of : String,
    items : Array(JsonMap),
    next_id : String? = nil,
    prev_id : String? = nil
  ) : JsonMap
    properties = JsonMap{
      "partOf"       => json(part_of),
      "orderedItems" => json(items),
    }
    properties["next"] = json(next_id) if next_id
    properties["prev"] = json(prev_id) if prev_id
    Aptok.object("OrderedCollectionPage", id, properties)
  end

  def self.collection_page(
    id : String,
    part_of : String,
    items : Array(JsonMap),
    next_id : String? = nil,
    prev_id : String? = nil
  ) : JsonMap
    properties = JsonMap{
      "partOf" => json(part_of),
      "items"  => json(items),
    }
    properties["next"] = json(next_id) if next_id
    properties["prev"] = json(prev_id) if prev_id
    Aptok.object("CollectionPage", id, properties)
  end

  def self.paginated_collection(
    id : String,
    items : Array(JsonMap),
    page : Int32? = nil,
    size : Int32 = 20
  ) : JsonMap
    normalized_size = size <= 0 ? 20 : size
    unless page
      collection = collection(id, [] of JsonMap, items.size)
      collection["first"] = json("#{id}?page=1")
      return collection
    end

    normalized_page = page < 1 ? 1 : page
    offset = (normalized_page - 1) * normalized_size
    page_items = items[offset, normalized_size]? || [] of JsonMap
    page_id = "#{id}?page=#{normalized_page}"
    next_id = offset + normalized_size < items.size ? "#{id}?page=#{normalized_page + 1}" : nil
    prev_id = normalized_page > 1 ? "#{id}?page=#{normalized_page - 1}" : nil
    collection_page(page_id, id, page_items, next_id, prev_id)
  end

  def self.paginated_ordered_collection(
    id : String,
    items : Array(JsonMap),
    page : Int32? = nil,
    size : Int32 = 20
  ) : JsonMap
    normalized_size = size <= 0 ? 20 : size
    unless page
      collection = ordered_collection(id, [] of JsonMap, items.size)
      collection["first"] = json("#{id}?page=1")
      return collection
    end

    normalized_page = page < 1 ? 1 : page
    offset = (normalized_page - 1) * normalized_size
    page_items = items[offset, normalized_size]? || [] of JsonMap
    page_id = "#{id}?page=#{normalized_page}"
    next_id = offset + normalized_size < items.size ? "#{id}?page=#{normalized_page + 1}" : nil
    prev_id = normalized_page > 1 ? "#{id}?page=#{normalized_page - 1}" : nil
    ordered_collection_page(page_id, id, page_items, next_id, prev_id)
  end

  def self.cursor_ordered_collection(
    id : String,
    total_items : Int32? = nil,
    first_cursor : String? = nil,
    last_cursor : String? = nil,
    size : Int32 = 20,
    page_base : String = id
  ) : JsonMap
    collection = ordered_collection(id, [] of JsonMap, total_items)
    collection["first"] = json(cursor_page_uri(page_base, first_cursor, size)) if first_cursor
    collection["last"] = json(cursor_page_uri(page_base, last_cursor, size)) if last_cursor
    collection
  end

  def self.cursor_collection(
    id : String,
    total_items : Int32? = nil,
    first_cursor : String? = nil,
    last_cursor : String? = nil,
    size : Int32 = 20,
    page_base : String = id
  ) : JsonMap
    collection = collection(id, [] of JsonMap, total_items)
    collection["first"] = json(cursor_page_uri(page_base, first_cursor, size)) if first_cursor
    collection["last"] = json(cursor_page_uri(page_base, last_cursor, size)) if last_cursor
    collection
  end

  def self.cursor_ordered_collection_page(
    id : String,
    part_of : String,
    items : Array(JsonMap),
    cursor : String? = nil,
    next_cursor : String? = nil,
    prev_cursor : String? = nil,
    size : Int32 = 20
  ) : JsonMap
    page_id = cursor ? cursor_page_uri(id, cursor, size) : id
    page = ordered_collection_page(
      page_id,
      part_of,
      items,
      next_cursor ? cursor_page_uri(part_of, next_cursor, size) : nil,
      prev_cursor ? cursor_page_uri(part_of, prev_cursor, size) : nil
    )
    page["cursor"] = json(cursor) if cursor
    page
  end
end
