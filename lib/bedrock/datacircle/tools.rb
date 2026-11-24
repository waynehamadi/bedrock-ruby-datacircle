# frozen_string_literal: true

module Aws
  module BedrockRuntime
    module Datacircle
      LIST_APIS = 'datacircle_list_apis'
      BEST_PLANS = 'datacircle_best_plans'
      SEARCH_PLANS = 'datacircle_search_plans'
      PROVIDER = 'datacircle_provider'

      # The four tools' names, in the order Tools#tools gives them. Their answers name each other by these names.
      NAMES = [LIST_APIS, BEST_PLANS, SEARCH_PLANS, PROVIDER].freeze

      PRICE = "perThousand is a plan's price of 1,000 items in dollars, pay the plan's whole price in its currency."

      # The four tools for the tool_config of Aws::BedrockRuntime::Client#converse and #converse_stream, and the run of
      # the tool uses the model makes.
      #
      #   datacircle = Aws::BedrockRuntime::Datacircle::Tools.new
      #   response = client.converse(model_id: ..., messages: messages, tool_config: { tools: datacircle.tools })
      #   messages << response.output.message.to_h
      #   answer = datacircle.results(messages.last) and messages << answer
      #
      # It holds no state: one can serve many threads.
      class Tools
        ABOUT = {
          LIST_APIS => "Lists the GTM APIs on Datacircle's sheet (https://datacircle.dev). GTM means go-to-market. GTM " \
                       "APIs are the APIs sales and marketing teams use. Gives each API's slug, how many plans and " \
                       "providers it has and its best plan. Call it first to find an API's slug.",
          BEST_PLANS => "Gives an API's plans best first by their score out of 100 on Datacircle's benchmark " \
                        '(https://datacircle.dev), each with its rank, provider, plan, $ per 1,000 calls and its page. ' \
                        "#{PRICE}",
          SEARCH_PLANS => "Searches every plan on Datacircle's sheet (https://datacircle.dev), or one API's, by provider " \
                          'or plan name, sorted by score, provider or price. Gives how many were found and up to limit ' \
                          "of them. #{PRICE}",
          PROVIDER => "Gives each API one provider sells and its rank on each on Datacircle's benchmark " \
                      '(https://datacircle.dev), with its best plan there, its best rank first. total is how many APIs ' \
                      'it sells, ranked on how many of them it has a rank. For an API\'s best providers, call ' \
                      'datacircle_best_plans.'
        }.freeze

        # Each tool's input: its keys in order, each [type, what the model is told, its bounds or choices, needed].
        INPUTS = {
          LIST_APIS => {
            'query' => [:text, "Words of the API's name or slug, like email or linkedin profile: the APIs that hold " \
                               "the most of them come first. Left out, the sheet's order"],
            'limit' => [:count, 'How many APIs to give, 1 to 200. 20 when left out: the sheet has about 150', [1, 200]]
          },
          BEST_PLANS => {
            'slug' => [:text, "The API's slug, like email-finder or linkedin-profile, as datacircle_list_apis gives it",
                       nil, true],
            'limit' => [:count, 'How many plans to give, 1 to 50. 10 when left out', [1, 50]]
          },
          SEARCH_PLANS => {
            'api' => [:text, "Only this API's plans: its name or slug, like email-finder. A provider's name goes in " \
                             'query, never here. Left out, every API'],
            'query' => [:text, "Words that must all appear in the provider's or plan's name, like bright data. Left " \
                               'out, every plan'],
            'sort' => [:choice, 'score (best first, the default), provider (A to Z) or price ($ per 1,000, lowest first)',
                       %w[score provider price]],
            'limit' => [:count, 'How many plans to give, 1 to 50. 10 when left out', [1, 50]],
            'offset' => [:count, 'How many found plans to skip first. 0 when left out', [0, nil]]
          },
          PROVIDER => {
            'slug' => [:text, "The provider's slug, like bright-data, or its name, like Bright Data: the name is made " \
                              'a slug', nil, true]
          }
        }.freeze

        # base_url: where the tools call, https://api.datacircle.dev/v1 when left out.
        def initialize(base_url: nil)
          @base_url = base_url || Client::BASE
        end

        # The four tools for tool_config: { tools: [...] } of #converse and #converse_stream, each a tool_spec Hash. A new
        # copy at each call: they can go beside the app's own tools.
        def tools
          NAMES.map do |name|
            { tool_spec: { name: name, description: ABOUT[name], input_schema: { json: schema(name) } } }
          end
        end

        # Whether name is one of the four tools'.
        def handles?(name)
          NAMES.include?(name.to_s)
        end

        # The tool uses of the model's message that the app answers, in order, each an
        # Aws::BedrockRuntime::Types::ToolUseBlock: every tool_use block but a system tool's, which Bedrock runs itself
        # (its type server_tool_use, or answered by a tool_result block of the same message). The message is
        # response.output.message of #converse, or a Hash like Collector#message's.
        def tool_uses(message)
          blocks = Array(field(message, :content))
          answered = blocks.filter_map { |block| field(field(block, :tool_result), :tool_use_id) }
          blocks.filter_map do |block|
            use = field(block, :tool_use)
            next if use.nil? || field(use, :type).to_s == 'server_tool_use' || answered.include?(field(use, :tool_use_id))

            Types::ToolUseBlock.new(tool_use_id: field(use, :tool_use_id).to_s, name: field(use, :name).to_s, input: field(use, :input))
          end
        end

        # The tool_result block that answers one tool use of the four tools', its text the tool's answer as JSON; nil
        # for a use of another tool, which the app runs itself. Never raises: an answer of 4xx, an input that doesn't
        # fit or a failed network is the model's to read, as {"error": "..."}.
        def result(tool_use)
          name = field(tool_use, :name).to_s
          return nil unless handles?(name)

          text_result(field(tool_use, :tool_use_id), JSON.generate(answer(name, field(tool_use, :input))))
        end

        # Answers each tool use of the model's message, in order, in one user message of tool_result blocks, for the
        # next request's messages: the four tools' uses by #result, the others by the block, which gets each as an
        # Aws::BedrockRuntime::Types::ToolUseBlock. What the block gives is the answer: text as it is, nil as {}, any
        # other value as JSON; what it raises, the model reads as {"error": "..."}. Bedrock wants every tool use of a turn
        # answered: with no block, the model reads {"error": "No tool is named ... here."} for each other tool's.
        # Gives nil when the message has no tool use to answer: it is the model's answer.
        def results(message, &own)
          uses = tool_uses(message)
          return nil if uses.empty?

          { role: 'user', content: uses.map { |use| result(use) || text_result(use.tool_use_id, own_answer(use, own)) } }
        end

        # The answer one tool gives the model, as a Hash: the input is a Hash (string or symbol keys), JSON text or nil.
        # An answer of 4xx, an input that doesn't fit the tool's schema or a failed network is {"error" => "..."}.
        # Raises ArgumentError when name is not one of the four tools'.
        def run(name, input = nil)
          raise ArgumentError, "No tool is named #{name.to_s.inspect}: the tools are #{NAMES.join(', ')}" unless handles?(name)

          answer(name.to_s, input)
        end

        private

        def schema(name)
          fields = INPUTS[name]
          properties = fields.to_h do |key, (type, about, rule)|
            property = { 'type' => type == :count ? 'integer' : 'string', 'description' => about }
            property['enum'] = rule.dup if type == :choice
            if type == :count
              property['minimum'] = rule[0]
              property['maximum'] = rule[1] if rule[1]
            end
            [key, property]
          end
          needed = fields.select { |_, (_, _, _, need)| need }.keys
          # No required list when none is needed, and no additionalProperties: the JSON schema every Bedrock model takes.
          needed.empty? ? { 'type' => 'object', 'properties' => properties } : { 'type' => 'object', 'properties' => properties, 'required' => needed }
        end

        def answer(name, input)
          arguments = check(name, read(input)).transform_keys(&:to_sym)
          calls = Calls.new(base_url: @base_url)
          case name
          when LIST_APIS then calls.list_apis(**arguments)
          when BEST_PLANS then calls.best_plans(**arguments)
          when SEARCH_PLANS then calls.search_plans(**arguments)
          when PROVIDER then calls.provider(**arguments)
          end
        rescue Error => e
          { 'error' => e.message }
        end

        # The tool use's input as a Hash of string keys: Converse gives a Hash; JSON text, as an app's own code may hold
        # it, is read as one; none is {}.
        def read(input)
          input = input.strip.empty? ? {} : JSON.parse(input) if input.is_a?(String)
          input = {} if input.nil?
          raise Error, "The input does not fit the tool's input schema: expected an object, got #{shown(input)}" unless input.is_a?(Hash)

          input.to_h { |key, value| [key.to_s, value] }
        rescue JSON::ParserError => e
          raise Error, "The input is not JSON: #{e.message}"
        end

        # The input checked against the tool's schema, looser than it so that a small model that strays is understood
        # where it can be: null is a key left out, a key of its own is dropped, a number sent as text is read as one, a
        # fraction cut to its whole part. What it refuses, the model reads why, each key, so that it can call again.
        def check(name, given)
          kept = {}
          refused = []
          INPUTS[name].each do |key, (type, _, rule, need)|
            value = given[key]
            if value.nil?
              refused << "#{key}: expected text, got nothing" if need
              next
            end
            case type
            when :text
              value.is_a?(String) ? kept[key] = value : refused << "#{key}: expected text, got #{shown(value)}"
            when :choice
              rule.include?(value) ? kept[key] = value : refused << "#{key}: expected one of #{rule.join(', ')}, got #{shown(value)}"
            when :count
              number = count(value)
              number ? kept[key] = number : refused << "#{key}: expected a number, got #{shown(value)}"
            end
          end
          raise Error, "The input does not fit the tool's input schema: #{refused.join('; ')}" unless refused.empty?

          kept
        end

        # A number, or one sent as text, as an Integer or a Float; nil for anything else.
        def count(value)
          value = Float(value.strip) if value.is_a?(String) && !value.strip.empty?
          value.is_a?(Numeric) && value.finite? ? value : nil
        rescue ArgumentError
          nil
        end

        def shown(value)
          value.nil? ? 'nothing' : JSON.generate(value)
        rescue JSON::GeneratorError, ::Encoding::UndefinedConversionError
          value.inspect
        end

        # The app's own answer to a use of another tool, as text.
        def own_answer(use, own)
          return error_text("No tool is named #{use.name.to_json} here.") unless own

          value = own.call(use)
          value.is_a?(String) ? value : value.nil? ? '{}' : JSON.generate(value)
        rescue StandardError => e
          error_text(e.message)
        end

        # A tool_result of one text block. A blank text is sent as {}: Bedrock refuses a blank one.
        def text_result(tool_use_id, text)
          { tool_result: { tool_use_id: tool_use_id.to_s, content: [{ text: text.strip.empty? ? '{}' : text }] } }
        end

        def error_text(message)
          JSON.generate('error' => message.to_s)
        end

        # A key of an SDK struct, or of a Hash as an app writes it (symbols) or holds it from JSON (strings).
        def field(item, key)
          case item
          when Struct then item.members.include?(key) ? item[key] : nil
          when Hash then item.key?(key) ? item[key] : item[key.to_s]
          end
        end
      end
    end
  end
end
