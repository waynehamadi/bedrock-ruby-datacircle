# Datacircle tools for Amazon Bedrock in the AWS SDK for Ruby

Find the best GTM APIs. We benchmark all the GTM APIs and we put the results on our website.

Our website: https://datacircle.dev

This gem gives Amazon Bedrock's Converse API four tools that call Datacircle's open API, https://api.datacircle.dev/v1. You pass the tools to `converse` or `converse_stream` of [aws-sdk-bedrockruntime](https://github.com/aws/aws-sdk-ruby). Bedrock does not run tools. This gem runs each call the model makes to a Datacircle tool. You get the answers to send back to the model. You need no key and no account.

| Tool | What the tool gives | Call |
| --- | --- | --- |
| `datacircle_list_apis` | Every GTM API on Datacircle, with the API's slug, number of plans, number of providers and best plan | `GET /apis` |
| `datacircle_best_plans` | One API's plans, sorted by score out of 100, best first. Each plan comes with a rank and a price per 1,000 calls | `GET /apis/{slug}/best` |
| `datacircle_search_plans` | Plans that match a provider or plan name, on all APIs or on one API. You can sort them by score, provider or price | `GET /plans` |
| `datacircle_provider` | The APIs a provider sells, and the provider's rank on each API | `GET /providers/{slug}` |

## Install

```bash
bundle add bedrock-datacircle
```

The gem needs Ruby 3.2 or later and `aws-sdk-bedrockruntime` 1.9.0 or later. Reasoning blocks need `aws-sdk-bedrockruntime` 1.39.0 or later.

## Use the tools with converse

Put `tools` in `tool_config`. Add the model's message to `messages`, then the answers that `results` gives:

```ruby
require "bedrock/datacircle"

client = Aws::BedrockRuntime::Client.new(region: "us-east-1")
datacircle = Aws::BedrockRuntime::Datacircle::Tools.new
messages = [{role: "user", content: [{text: "Who are the 3 best providers for the email-finder API?"}]}]

loop do
  response = client.converse(model_id: "amazon.nova-pro-v1:0", messages: messages, tool_config: {tools: datacircle.tools})
  message = response.output.message.to_h
  messages << message
  answers = datacircle.results(message)
  break puts(message[:content].filter_map { _1[:text] }.join) unless answers

  messages << answers
end
```

`results` gives one user message with a `tool_result` for each tool the model used, in order. You get `nil` when the model used no tool.

Add `response.output.message.to_h` to your messages, not `response.output.message`. `aws-sdk-core` before 3.201.2 refuses the SDK's own message when you send it back. A Hash works on every version.

## Use the tools with converse_stream

Give the stream to a `Collector` in the block of `converse_stream`. After the stream ends, `collector.message` gives the model's message:

```ruby
messages = [{role: "user", content: [{text: "Which provider ranks first for the SERP API?"}]}]

loop do
  collector = Aws::BedrockRuntime::Datacircle::Collector.new
  client.converse_stream(model_id: "amazon.nova-pro-v1:0", messages: messages, tool_config: {tools: datacircle.tools}) do |stream|
    collector.listen(stream) { |text| print text }
  end
  message = collector.message
  messages << message
  answers = datacircle.results(message) or break
  messages << answers
end
puts
```

The collector builds the model's message from the events: the text, the reasoning and each tool input. The block of `listen` gets each piece of text as it comes. `listen` also takes an `event_stream_handler` of yours. When you read the stream after the call, use `Aws::BedrockRuntime::Datacircle::Collector.collect(response.stream)`. `collector.message` raises the stream's error event, such as a `ThrottlingException`.

## Your own tools

Bedrock needs an answer to each tool the model used in a turn. If you add tools of your own, give `results` a block. The block gets each use of one of your tools as an `Aws::BedrockRuntime::Types::ToolUseBlock`, with `tool_use_id`, `name` and `input`. The block returns the answer as a String, or as a Hash that the gem sends as JSON:

```ruby
get_time = {tool_spec: {name: "get_time", description: "The time now in a time zone, like +02:00",
                        input_schema: {json: {type: "object", properties: {zone: {type: "string"}}, required: ["zone"]}}}}
tool_config = {tools: [*datacircle.tools, get_time]}

answers = datacircle.results(message) { |use| {time: Time.now.getlocal(use.input["zone"]).strftime("%H:%M")} }
```

When the block raises, the model reads `{"error": "..."}` with the message. Leave out the block and the model reads an error for each use of your tools. `datacircle.handles?(name)` tells you if the tool named `name` is one of ours. `datacircle.result(tool_use)` answers one use of a Datacircle tool and gives `nil` for any other tool.

## Call a tool yourself

You can call a tool without a model. You get the tool's answer as a Hash:

```ruby
Aws::BedrockRuntime::Datacircle::Tools.new.run("datacircle_best_plans", {"slug" => "email-finder", "limit" => 3})
# => {"api" => "Employee email", "slug" => "email-finder", ..., "plans" => [{"api" => "Employee email", "rank" => 1, ...}]}
```

`Aws::BedrockRuntime::Datacircle::Calls.new` makes the same calls. The methods of `Calls` are `list_apis`, `best_plans`, `search_plans` and `provider`.

## What the model reads

Each tool gives the model a JSON object as the text of the `tool_result`. Each plan comes with a rank, provider, plan, score, price per 1,000 (`perThousand`, in dollars) and a page on datacircle.dev. That page lists every field. A tool also takes an API's name or a provider's name in place of a slug.

For an unknown slug, the model reads `{"error": "..."}` with the API's message and what to send instead. If the input does not fit the schema, the error names each wrong field. If the network fails, the error gives the network's message. The model can read the error, call the tool again and keep going. `run` gives the same errors as `{"error" => "..."}`. `Calls` raises a network error as `Aws::BedrockRuntime::Datacircle::Error`.

`Aws::BedrockRuntime::Datacircle::Tools.new(base_url: ...)` sets a new address for the tools, for example a proxy of yours. Leave `base_url` out and the tools call https://api.datacircle.dev/v1.

## Network

Each tool call sends HTTPS GET requests to https://api.datacircle.dev/v1 and nowhere else. Most calls send one request. A tool sends up to four when the model gives a name in place of a slug. The requests hold only the tool's input from the model: no key and nothing from your messages. The API takes up to 60 calls a minute from one IP address. A tool waits once, for a minute at most, when the API asks for a wait. The gem's one dependency is `aws-sdk-bedrockruntime`. The gem stores nothing.

## Links

- Datacircle: https://datacircle.dev
- The API: https://datacircle.dev/api
- The API's spec: https://api.datacircle.dev/v1/openapi.json
- What each key means: https://datacircle.dev/fields

MIT license.
