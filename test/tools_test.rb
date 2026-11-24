# frozen_string_literal: true

# Offline: ruby -Ilib test/tools_test.rb
require 'minitest/autorun'
require 'bedrock/datacircle'

class ToolsTest < Minitest::Test
  D = Aws::BedrockRuntime::Datacircle
  T = Aws::BedrockRuntime::Types

  def setup
    # A closed port: a call of ours answers {"error": ...} with no network.
    @tools = D::Tools.new(base_url: 'http://127.0.0.1:9/v1')
  end

  def test_specs
    specs = @tools.tools
    assert_equal D::NAMES, specs.map { |t| t[:tool_spec][:name] }
    assert(specs.all? { |t| t[:tool_spec][:input_schema][:json]['type'] == 'object' })
    assert_equal %w[score provider price], specs[2][:tool_spec][:input_schema][:json]['properties']['sort']['enum']
  end

  def test_tool_uses_leave_out_a_system_tool
    message = { role: 'assistant', content: [
      { text: 'Looking.' },
      { tool_use: { tool_use_id: 'a', name: 'datacircle_list_apis', input: {} } },
      { tool_use: { tool_use_id: 'b', name: 'web_grounding', input: {}, type: 'server_tool_use' } },
      { tool_use: { tool_use_id: 'c', name: 'search', input: {} } },
      { tool_result: { tool_use_id: 'c', content: [{ text: 'done by Bedrock' }] } },
      { 'tool_use' => { 'tool_use_id' => 'd', 'name' => 'get_time', 'input' => { 'zone' => 'UTC' } } }
    ] }
    uses = @tools.tool_uses(message)
    assert_equal %w[a d], uses.map(&:tool_use_id)
    assert_kind_of T::ToolUseBlock, uses.last
    assert_equal({ 'zone' => 'UTC' }, uses.last.input)
  end

  def test_tool_uses_of_an_sdk_message
    message = T::Message.new(role: 'assistant', content: [
      T::ContentBlock::Text.new(text: 'Calling.'),
      T::ContentBlock::ToolUse.new(tool_use: T::ToolUseBlock.new(tool_use_id: 'x', name: 'datacircle_provider', input: { 'slug' => 'apollo' }))
    ])
    assert_equal ['x'], @tools.tool_uses(message).map(&:tool_use_id)
  end

  def test_results_nil_with_no_tool_use
    assert_nil @tools.results({ role: 'assistant', content: [{ text: 'The answer.' }] })
  end

  def test_results_in_order_each_answered
    message = { role: 'assistant', content: [
      { tool_use: { tool_use_id: '1', name: 'get_time', input: { 'zone' => 'UTC' } } },
      { tool_use: { tool_use_id: '2', name: 'datacircle_provider', input: {} } },
      { tool_use: { tool_use_id: '3', name: 'get_weather', input: {} } },
      { tool_use: { tool_use_id: '4', name: 'datacircle_list_apis', input: {} } }
    ] }
    answer = @tools.results(message) do |use|
      raise 'no such tool' unless use.name == 'get_time'

      { time: "12:00 #{use.input['zone']}" }
    end
    assert_equal 'user', answer[:role]
    assert_equal %w[1 2 3 4], answer[:content].map { |b| b[:tool_result][:tool_use_id] }
    texts = answer[:content].map { |b| b[:tool_result][:content][0][:text] }
    assert_equal '{"time":"12:00 UTC"}', texts[0]
    assert_equal '{"error":"The input does not fit the tool\'s input schema: slug: expected text, got nothing"}', texts[1]
    assert_equal '{"error":"no such tool"}', texts[2]
    assert texts[3].start_with?('{"error":"Datacircle\'s API could not be reached')
  end

  def test_own_tool_with_no_block_and_blank_answers
    message = { role: 'assistant', content: [{ tool_use: { tool_use_id: '1', name: 'get_time', input: {} } }] }
    assert_equal '{"error":"No tool is named \"get_time\" here."}', @tools.results(message)[:content][0][:tool_result][:content][0][:text]
    assert_equal '{}', @tools.results(message) { nil }[:content][0][:tool_result][:content][0][:text]
    assert_equal '{}', @tools.results(message) { '  ' }[:content][0][:tool_result][:content][0][:text]
    assert_equal 'as is', @tools.results(message) { 'as is' }[:content][0][:tool_result][:content][0][:text]
  end

  def test_input_checks
    assert_equal "The input does not fit the tool's input schema: sort: expected one of score, provider, price, got " \
                 '"cheapest"; limit: expected a number, got true', @tools.run('datacircle_search_plans', { limit: true, sort: 'cheapest' })['error']
    assert_equal "The input does not fit the tool's input schema: slug: expected text, got 3", @tools.run('datacircle_best_plans', { slug: 3 })['error']
    assert_raises(ArgumentError) { @tools.run('get_time') }
  end

  def event(type, **values)
    klass = { content_block_start: T::ContentBlockStartEvent, content_block_delta: T::ContentBlockDeltaEvent,
              content_block_stop: T::ContentBlockStopEvent, message_start: T::MessageStartEvent,
              message_stop: T::MessageStopEvent }.fetch(type)
    klass.new(**values, event_type: type)
  end

  def delta(index, **union)
    key, value = union.first
    klass = { text: T::ContentBlockDelta::Text, tool_use: T::ContentBlockDelta::ToolUse,
              reasoning_content: T::ContentBlockDelta::ReasoningContent }.fetch(key)
    event(:content_block_delta, content_block_index: index, delta: klass.new(key => value))
  end

  def turn
    [event(:message_start, role: 'assistant'),
     delta(0, reasoning_content: T::ReasoningContentBlockDelta::Text.new(text: 'Think')),
     delta(0, reasoning_content: T::ReasoningContentBlockDelta::Text.new(text: 'ing.')),
     delta(0, reasoning_content: T::ReasoningContentBlockDelta::Signature.new(signature: 'sig')),
     delta(1, text: 'Call'), delta(1, text: 'ing.'),
     event(:content_block_start, content_block_index: 2,
                                 start: T::ContentBlockStart::ToolUse.new(tool_use: T::ToolUseBlockStart.new(tool_use_id: 't1', name: 'datacircle_best_plans'))),
     delta(2, tool_use: T::ToolUseBlockDelta.new(input: '{"slug":')), delta(2, tool_use: T::ToolUseBlockDelta.new(input: '"serp"}')),
     event(:content_block_stop, content_block_index: 2),
     event(:content_block_start, content_block_index: 3,
                                 start: T::ContentBlockStart::ToolUse.new(tool_use: T::ToolUseBlockStart.new(tool_use_id: 't2', name: 'datacircle_list_apis'))),
     delta(4, text: ' '),
     event(:message_stop, stop_reason: 'tool_use')]
  end

  def test_collector
    shown = +''
    message = D::Collector.collect(turn) { |text| shown << text }
    assert_equal 'Calling. ', shown
    assert_equal({ role: 'assistant', content: [
                   { reasoning_content: { reasoning_text: { text: 'Thinking.', signature: 'sig' } } },
                   { text: 'Calling.' },
                   { tool_use: { tool_use_id: 't1', name: 'datacircle_best_plans', input: { 'slug' => 'serp' } } },
                   { tool_use: { tool_use_id: 't2', name: 'datacircle_list_apis', input: {} } }
                 ] }, message)
  end

  def test_collector_starts_over_on_a_new_attempt
    collector = D::Collector.new
    (turn.first(5) + turn).each { |e| collector.add(e) }
    assert_equal 'tool_use', collector.stop_reason
    assert_equal 4, collector.message[:content].size
    assert_equal({ text: 'Calling.' }, collector.message[:content][1])
  end

  def test_collector_keeps_an_error_for_message
    collector = D::Collector.new
    collector.add(event(:message_start, role: 'assistant'))
    collector.add(T::ThrottlingException.new(message: 'Slow down', event_type: :throttling_exception))
    error = assert_raises(Aws::BedrockRuntime::Errors::ThrottlingException) { collector.message }
    assert_equal 'Slow down', error.message
    collector = D::Collector.new
    collector.add(Aws::Errors::EventError.new(:error, 'Unknown', 'odd'))
    assert_raises(Aws::Errors::EventError) { collector.message }
  end

  def test_collector_system_tool_result
    collector = D::Collector.new
    collector.add(event(:content_block_start, content_block_index: 0,
                                              start: T::ContentBlockStart::ToolResult.new(tool_result: T::ToolResultBlockStart.new(tool_use_id: 's1', type: 'x', status: 'success'))))
    collector.add(event(:content_block_delta, content_block_index: 0,
                                              delta: T::ContentBlockDelta::ToolResult.new(tool_result: [T::ToolResultBlockDelta::Text.new(text: 'fo'), T::ToolResultBlockDelta::Text.new(text: 'und')])))
    assert_equal({ tool_result: { tool_use_id: 's1', content: [{ text: 'found' }], type: 'x', status: 'success' } }, collector.message[:content][0])
  end
end
