require "./spec_helper"
require "yaml"

describe "project naming" do
  it "uses the Aptok public namespace" do
    Aptok::VERSION.should be_a(String)
  end

  it "uses aptok as the shard name" do
    shard = YAML.parse(File.read("#{__DIR__}/../shard.yml"))

    shard["name"].as_s.should eq("aptok")
    shard["targets"]["aptok"]["main"].as_s.should eq("src/aptok.cr")
  end
end
