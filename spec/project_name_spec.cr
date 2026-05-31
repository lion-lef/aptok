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

  it "keeps documentation on the aptok project name" do
    readme = File.read("#{__DIR__}/../README.md")
    readme.should contain("# Aptok")
    readme.should contain("require \"aptok\"")
    readme.should_not contain("aptork")
    readme.should_not contain("Aptork")
  end

  it "keeps the example server type-checking" do
    example = File.read("#{__DIR__}/../examples/server.cr")
    example.should_not contain("Aptork")
    example.should_not contain("aptork")
    example.should_not contain("set_inbox_listeners")
    example.should_not contain("set_outbox_dispatcher")

    status = Process.run(
      "crystal",
      ["build", "examples/server.cr", "--no-codegen"],
      output: Process::Redirect::Close,
      error: Process::Redirect::Inherit
    )
    status.success?.should be_true
  end
end
