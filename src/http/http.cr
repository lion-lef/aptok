module Aptok
  record Request,
    method : String,
    path : String,
    headers : Hash(String, String) = Hash(String, String).new,
    query : Hash(String, String) = Hash(String, String).new,
    body : String = ""

  record Response,
    status : Int32,
    headers : Hash(String, String),
    body : String
end
