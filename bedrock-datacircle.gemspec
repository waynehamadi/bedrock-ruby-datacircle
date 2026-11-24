# frozen_string_literal: true

require_relative 'lib/bedrock/datacircle/version'

Gem::Specification.new do |spec|
  spec.name          = 'bedrock-datacircle'
  spec.version       = Aws::BedrockRuntime::Datacircle::VERSION
  spec.authors       = ['Wayne Hamadi']
  spec.email         = ['wayne@datacircle.dev']

  spec.summary       = 'Amazon Bedrock Converse tools that find the best GTM APIs, for the AWS SDK for Ruby.'
  spec.description   = 'Four tools for the Converse API of aws-sdk-bedrockruntime call Datacircle\'s open API with no ' \
                       'key. List the GTM APIs and each API\'s best plans. Search every plan, or see where one provider ' \
                       'ranks in our benchmarks. We benchmark all the GTM APIs and we put the results on our website: ' \
                       'https://datacircle.dev'
  spec.homepage      = 'https://datacircle.dev'
  spec.license       = 'MIT'
  spec.metadata      = {
    'homepage_uri' => 'https://datacircle.dev',
    'source_code_uri' => 'https://github.com/waynehamadi/bedrock-ruby-datacircle',
    'documentation_uri' => 'https://github.com/waynehamadi/bedrock-ruby-datacircle#readme',
    'bug_tracker_uri' => 'https://github.com/waynehamadi/bedrock-ruby-datacircle/issues'
  }

  spec.files         = Dir['LICENSE.txt', 'README.md', 'lib/**/*.rb']
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 3.2.0'

  spec.add_dependency 'aws-sdk-bedrockruntime', '>= 1.9.0', '< 2'
end
