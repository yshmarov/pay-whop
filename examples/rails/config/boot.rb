ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../../Gemfile", __dir__)
require "bundler/setup"
require "dotenv"
Dotenv.load(File.expand_path("../../../.env", __dir__))
