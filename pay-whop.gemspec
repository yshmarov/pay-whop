require_relative "lib/pay/whop/version"

Gem::Specification.new do |spec|
  spec.name = "pay-whop"
  spec.version = Pay::Whop::VERSION
  spec.authors = ["Yaroslav Shmarov"]
  spec.summary = "Whop payments for the Pay Rails engine"
  spec.description = "A community Pay adapter for Whop checkout, subscriptions, saved methods, invoices, refunds, marketplace subaccounts and verified webhooks."
  spec.homepage = "https://github.com/yshmarov/pay-whop"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["{app,config,db,lib,docs}/**/*", "README.md", "CHANGELOG.md", "LICENSE"].select { |path| File.file?(path) }
  spec.require_paths = ["lib"]
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.add_dependency "pay", "~> 12.3"
  spec.add_dependency "whop_sdk", "~> 2.7.0"
end
