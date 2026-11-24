# frozen_string_literal: true

module Aws
  module BedrockRuntime
    module Datacircle
      # Gathers #converse_stream's events into the model's message, as #converse gives it in output.message: its text,
      # its reasoning, with the signature Bedrock wants back beside a tool use, and each tool use, whose input comes in
      # pieces of JSON. Other blocks (images, citations) are left out.
      #
      #   collector = Aws::BedrockRuntime::Datacircle::Collector.new
      #   client.converse_stream(model_id: ..., messages: messages, tool_config: config) do |stream|
      #     collector.listen(stream) { |text| print text }
      #   end
      #   messages << collector.message
      #
      # or, once a stream read whole: Collector.collect(response.stream). One collector gathers one stream.
      class Collector
        # The SDK's events that carry an error of the stream, and the error each is raised as.
        ERRORS = %i[internal_server_exception model_stream_error_exception validation_exception throttling_exception
                    service_unavailable_exception].freeze

        # The stream's stop reason, from its message_stop event: "tool_use" when the model used tools.
        attr_reader :stop_reason
        # The stream's metadata event: its usage and metrics.
        attr_reader :metadata
        # The stream's error event (a throttling, a validation...), which #message raises: the SDK's own error, like
        # Aws::BedrockRuntime::Errors::ThrottlingException, or the SDK's Aws::Errors::EventError.
        attr_reader :error

        # The model's message of a stream read whole (response.stream of #converse_stream with no block), as #message
        # gives it, or its error event raised. Each piece of text goes to the block, for an app that shows it.
        def self.collect(events, &on_text)
          collector = new
          Array(events).each do |event|
            text = collector.add(event)
            on_text&.call(text) unless text.empty?
          end
          collector.message
        end

        def initialize
          @blocks = {}
          @stop_reason = @metadata = @error = nil
        end

        # Has the stream of #converse_stream's block (an Aws::BedrockRuntime::EventStreams::ConverseStreamOutput) give
        # this collector each event as it comes, and the block each piece of the answer's text. An error event is kept
        # for #message to raise once #converse_stream is done: raised in the SDK's own callback, a throttling would
        # make the SDK send the request again.
        def listen(stream, &on_text)
          stream.on_event do |event|
            text = add(event)
            on_text&.call(text) unless text.empty?
          end
          self
        end

        # Takes the stream's next event and gives the text it adds to the model's answer, '' for none. An error event is
        # kept in #error, for #message to raise. A message_start starts the message over: the SDK sends a request
        # again after some failures, and its events come again from the start.
        def add(event)
          type = event.is_a?(Exception) ? :error : field(event, :event_type)&.to_sym
          if type == :error || ERRORS.include?(type)
            @error ||= event.is_a?(Exception) ? event : error(type, event)
            return ''
          end

          case type
          when :message_start then initialize
          when :content_block_start then start(event)
          when :content_block_delta then return delta(event)
          when :message_stop then @stop_reason = field(event, :stop_reason)
          when :metadata then @metadata = event
          end
          ''
        end

        # The model's message the events make, for the next request's messages and for Tools#results: a Hash of
        # symbol keys, as #converse and #converse_stream take it. A tool use's input that is no JSON object, like none
        # at all, is given as {}: Bedrock takes only an object. A blank text is left out, as Bedrock refuses it. Raises
        # the stream's error event, if it had one.
        def message
          raise @error if @error

          content = @blocks.sort_by(&:first).filter_map { |_, block| block_of(block) }
          { role: 'assistant', content: content }
        end

        # The text of the model's answer so far.
        def text
          @blocks.sort_by(&:first).map { |_, block| block[:text] }.join
        end

        private

        def block(index)
          @blocks[index.to_i] ||= { text: +'', reasoning: +'', signature: +'', redacted: [], input: +'' }
        end

        def start(event)
          start = field(event, :start)
          if (use = field(start, :tool_use))
            block(field(event, :content_block_index))[:use] = { tool_use_id: field(use, :tool_use_id).to_s, name: field(use, :name).to_s,
                                                                type: field(use, :type) }
          elsif (result = field(start, :tool_result))
            block(field(event, :content_block_index))[:result] = { tool_use_id: field(result, :tool_use_id).to_s, type: field(result, :type),
                                                                   status: field(result, :status), content: [] }
          end
        end

        def delta(event)
          delta = field(event, :delta)
          block = block(field(event, :content_block_index))
          if (text = field(delta, :text)).is_a?(String)
            block[:text] << text
            return text
          end
          if (use = field(delta, :tool_use))
            block[:input] << field(use, :input).to_s
          end
          if (reasoning = field(delta, :reasoning_content))
            block[:reasoning] << field(reasoning, :text) if field(reasoning, :text).is_a?(String)
            block[:signature] << field(reasoning, :signature) if field(reasoning, :signature).is_a?(String)
            block[:redacted] << field(reasoning, :redacted_content) if field(reasoning, :redacted_content)
          end
          Array(field(delta, :tool_result)).each do |part|
            block[:result] ||= { tool_use_id: '', content: [] }
            parts = block[:result][:content]
            if (piece = field(part, :text)).is_a?(String)
              parts.last&.key?(:text) ? parts.last[:text] += piece : parts << { text: piece }
            elsif !field(part, :json).nil?
              parts << { json: field(part, :json) }
            end
          end
          ''
        end

        def block_of(block)
          if block[:use]
            use = { tool_use_id: block[:use][:tool_use_id], name: block[:use][:name], input: object(block[:input]) }
            use[:type] = 'server_tool_use' if block[:use][:type].to_s == 'server_tool_use'
            { tool_use: use }
          elsif block[:result]
            result = block[:result]
            return nil if result[:content].empty?

            kept = { tool_use_id: result[:tool_use_id], content: result[:content] }
            kept[:type] = result[:type] if result[:type]
            kept[:status] = result[:status] if %w[success error].include?(result[:status].to_s)
            { tool_result: kept }
          elsif block[:redacted].any?
            { reasoning_content: { redacted_content: block[:redacted].join } }
          elsif !block[:reasoning].empty? || !block[:signature].empty?
            text = { text: block[:reasoning] }
            text[:signature] = block[:signature] unless block[:signature].empty?
            { reasoning_content: { reasoning_text: text } }
          elsif !block[:text].strip.empty?
            { text: block[:text] }
          end
        end

        # A tool use's input from its pieces: the JSON object they make, {} for none or for anything else.
        def object(input)
          parsed = JSON.parse(input)
          parsed.is_a?(Hash) ? parsed : {}
        rescue JSON::ParserError
          {}
        end

        def error(type, event)
          name = type.to_s.split('_').map(&:capitalize).join
          message = field(event, :message)
          if defined?(Errors) && Errors.const_defined?(name, false)
            Errors.const_get(name, false).new(nil, message, event)
          else
            Aws::Errors::EventError.new(type, name, message)
          end
        end

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
