# frozen_string_literal: true

require 'json'
require 'aws-sdk-bedrockruntime'
require_relative 'datacircle/version'
require_relative 'datacircle/client'
require_relative 'datacircle/calls'
require_relative 'datacircle/tools'
require_relative 'datacircle/collector'

module Aws
  module BedrockRuntime
    # Datacircle's open API as four tools for Amazon Bedrock's Converse API, with no key: find the best GTM APIs. We
    # benchmark all the GTM APIs and we put the results on our website, https://datacircle.dev
    #
    #   datacircle = Aws::BedrockRuntime::Datacircle::Tools.new
    #   client.converse(model_id: ..., messages: messages, tool_config: { tools: datacircle.tools })
    #
    # datacircle_list_apis, datacircle_best_plans, datacircle_search_plans and datacircle_provider make one GET of
    # https://api.datacircle.dev/v1 each. Tools#results answers the model's tool uses in one user message of tool_result
    # blocks; Collector gathers #converse_stream's events into the model's message. The API's error, or why it could
    # not be reached, goes to the model as {"error": ...}.
    module Datacircle
    end
  end
end
