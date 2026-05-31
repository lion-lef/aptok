module Aptok
  def self.cursor_collection_page(
    id : String,
    part_of : String,
    items : Array(JsonMap),
    cursor : String? = nil,
    next_cursor : String? = nil,
    prev_cursor : String? = nil,
    size : Int32 = 20
  ) : JsonMap
    page_id = cursor ? cursor_page_uri(id, cursor, size) : id
    page = collection_page(
      page_id,
      part_of,
      items,
      next_cursor ? cursor_page_uri(part_of, next_cursor, size) : nil,
      prev_cursor ? cursor_page_uri(part_of, prev_cursor, size) : nil
    )
    page["cursor"] = json(cursor) if cursor
    page
  end

  def self.cursor_page_uri(base : String, cursor : String, size : Int32 = 20) : String
    uri = URI.parse(base)
    params = uri.query ? URI::Params.parse(uri.query.not_nil!) : URI::Params.new
    params.delete("cursor") if params.has_key?("cursor")
    params.delete("size") if params.has_key?("size")
    params["cursor"] = cursor
    params["size"] = size.to_s
    uri.query = params.to_s
    uri.to_s
  end
end
