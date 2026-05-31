require "http/server"
require "./http"

module Aptok
  def self.request_from_http(request : HTTP::Request) : Request
    query = Hash(String, String).new
    request.query_params.each do |key, value|
      query[key] ||= value
    end

    headers = Hash(String, String).new
    request.headers.each do |key, values|
      headers[key] = values.join(", ")
    end

    Request.new(
      request.method,
      request.path,
      headers: headers,
      query: query,
      body: request.body.try(&.gets_to_end) || ""
    )
  end

  def self.write_http_response(response : Response, target : HTTP::Server::Response) : Nil
    target.status = HTTP::Status.new(response.status)
    response.headers.each do |key, value|
      target.headers[key] = value
    end
    target.print response.body
  end
end
