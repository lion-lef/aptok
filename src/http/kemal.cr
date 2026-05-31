require "kemal"

require "../http/http"

module Aptok
  def self.request_from_kemal(context : ::HTTP::Server::Context) : Request
    query = Hash(String, String).new
    context.request.query_params.each do |key, value|
      query[key] ||= value
    end

    headers = Hash(String, String).new
    context.request.headers.each do |key, values|
      headers[key] = values.join(", ")
    end

    Request.new(
      context.request.method,
      context.request.path,
      headers: headers,
      query: query,
      body: context.request.body.try(&.gets_to_end) || ""
    )
  end

  def self.write_kemal_response(response : Response, context : ::HTTP::Server::Context) : Nil
    context.response.status_code = response.status
    response.headers.each do |key, value|
      context.response.headers[key] = value
    end
    context.response.print response.body
  end

  def self.handle_kemal_request(federation : Federation, request : ::HTTP::Server::Context, options : FetchOptions = FetchOptions.new) : Aptok::Response
    aptok_request = request_from_kemal(request)
    federation.fetch(aptok_request, options)
  end

  def self.kemal_handler(
    federation : Federation,
    options : FetchOptions = FetchOptions.new
  ) : Proc(::HTTP::Server::Context, Nil)
    ->(context : ::HTTP::Server::Context) do
      response = handle_kemal_request(federation, context, options)
      write_kemal_response(response, context)
      nil
    end
  end
end
