// AIToolCallFixtures.swift
// Wire fixtures for streamed tool calls (spike 2.1) on the four AI wires: Messages API,
// Chat Completions, Responses API and Gemini streamGenerateContent. Each group says which parts
// are copied verbatim from the vendor docs and which are assembled from a documented schema,
// so the phase 8 parsers know what they can rely on. Values (ids, model names) are the docs'.

nonisolated enum AIToolCallFixtures {

  // MARK: - Messages API (Anthropic)
  //
  // Sources, accessed 2026-10-19:
  // - https://platform.claude.com/docs/en/build-with-claude/streaming.md
  // - https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview.md
  // - https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls.md
  //
  // Every event has an SSE `event:` name equal to its data `type`. Streams may hold any number
  // of `ping` events, and unknown event types must be ignored. Tool input arrives as
  // `input_json_delta.partial_json` strings: the first one is "", only the concatenation of all
  // pieces (complete at `content_block_stop`) is valid JSON. The doc's standalone
  // input_json_delta sample ends with an unbalanced extra "}"; it is NOT used here.

  /// Verbatim: the request body of streaming.md "Streaming request with tool use" (cURL).
  static let messagesToolRequest = #"""
    {
      "model": "claude-opus-5",
      "max_tokens": 1024,
      "tools": [
        {
          "name": "get_weather",
          "description": "Get the current weather in a given location",
          "input_schema": {
            "type": "object",
            "properties": {
              "location": {
                "type": "string",
                "description": "The city and state, e.g. San Francisco, CA"
              }
            },
            "required": ["location"]
          }
        }
      ],
      "tool_choice": {"type": "any"},
      "messages": [
        {
          "role": "user",
          "content": "What is the weather like in San Francisco?"
        }
      ],
      "stream": true
    }
    """#

  /// Verbatim: the full SSE response of that request (streaming.md), nothing omitted. A text
  /// block (index 0), a `ping`, then the tool_use block (index 1) with `"input":{}`.
  static let messagesToolUseStream = #"""
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_014p7gG3wDgGV9EUtLvnow3U","type":"message","role":"assistant","model":"claude-opus-5","stop_sequence":null,"usage":{"input_tokens":472,"output_tokens":2},"content":[],"stop_reason":null}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: ping
    data: {"type": "ping"}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Okay"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":","}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" let"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"'s"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" check"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" the"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" weather"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" for"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" San"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" Francisco"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":","}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" CA"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":":"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01T1x1fJ34qAmk2tNTrN7Up6","name":"get_weather","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"location\":"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" \"San"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" Francisc"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"o,"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" CA\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":89}}

    event: message_stop
    data: {"type":"message_stop"}

    """#

  /// Assembled: the assistant turn of the next request. overview.md sends the response's
  /// `content` array back unchanged as `{role: "assistant", content: ...}`; the content here is
  /// the verbatim non-streamed tool_use response of handle-tool-calls.md, so its id matches the
  /// two tool_result turns below.
  static let messagesAssistantEchoTurn = #"""
    {
      "role": "assistant",
      "content": [
        {
          "type": "text",
          "text": "I'll check the current weather in San Francisco for you."
        },
        {
          "type": "tool_use",
          "id": "toolu_01A09q90qw90lq917835lq9",
          "name": "get_weather",
          "input": { "location": "San Francisco, CA", "unit": "celsius" }
        }
      ]
    }
    """#

  /// Verbatim (handle-tool-calls.md): the tool_result user turn. It must directly follow the
  /// assistant tool_use turn, and tool_result blocks come first in its content.
  static let messagesToolResultTurn = #"""
    {
      "role": "user",
      "content": [
        {
          "type": "tool_result",
          "tool_use_id": "toolu_01A09q90qw90lq917835lq9",
          "content": "15 degrees"
        }
      ]
    }
    """#

  /// Verbatim (handle-tool-calls.md): the failed-tool variant, `"is_error": true`.
  static let messagesToolResultErrorTurn = #"""
    {
      "role": "user",
      "content": [
        {
          "type": "tool_result",
          "tool_use_id": "toolu_01A09q90qw90lq917835lq9",
          "content": "ConnectionError: the weather service API is not available (HTTP 500)",
          "is_error": true
        }
      ]
    }
    """#

  // MARK: - Chat Completions (OpenAI-compatible)
  //
  // Sources, accessed 2026-10-19:
  // - https://platform.openai.com/docs/guides/function-calling (canonical
  //   https://developers.openai.com/api/docs/guides/function-calling, "api-mode=chat" samples)
  // - https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events.md
  // - https://developers.openai.com/api/reference/resources/chat.md
  //
  // Verbatim in the docs: the chunk envelope (`chatcmpl-123` example: id, object, created,
  // model, system_fingerprint, choices[].index/delta/logprobs/finish_reason), the `data: ` framing
  // with no `event:` lines, the final `data: [DONE]`, and the SDK-printed `delta.tool_calls`
  // values ("Output delta.tool_calls"): first fragment {index, id, type "function",
  // function.name, function.arguments ""}, later fragments only add function.arguments pieces.
  //
  // NOT DOCUMENTED verbatim, so assembled from the chunk schema + those SDK fragments:
  // - a raw `data:` line whose delta carries `tool_calls` (the full envelope around a fragment);
  // - a streamed chunk with `"finish_reason":"tool_calls"` (only a schema enum value and the
  //   non-streamed response show it); here it rides an empty `delta` like the docs' "stop" chunk;
  // - whether later fragments omit id/type/function.name or send them as JSON null. The schema
  //   says "optional" and the SDK print shows null, so parsers must accept both: the main stream
  //   omits them, `chatCompletionsNullFragmentStream` sends `"id": null, "type": null`.
  // - `"content":null` next to `"role":"assistant"` in the first delta (mirrors the non-streamed
  //   message's `content: null`); parsers must treat null content as no text.

  /// Verbatim (chat.md "Functions" example): the `tools` array and `tool_choice` of a request.
  /// The example's "model" and "messages" were left out; the guide adds `stream: true`.
  static let chatCompletionsToolsRequest = #"""
    {
      "tools": [
        {
          "type": "function",
          "function": {
            "name": "get_current_weather",
            "description": "Get the current weather in a given location",
            "parameters": {
              "type": "object",
              "properties": {
                "location": {
                  "type": "string",
                  "description": "The city and state, e.g. San Francisco, CA"
                },
                "unit": {
                  "type": "string",
                  "enum": ["celsius", "fahrenheit"]
                }
              },
              "required": ["location"]
            }
          }
        }
      ],
      "tool_choice": "auto",
      "stream": true
    }
    """#

  /// Assembled (see the group comment): one tool call, later fragments omit id/type/name.
  /// Joined arguments: `{"location":"Paris, France"}` (the guide's accumulated final_tool_calls).
  static let chatCompletionsToolCallStream = #"""
    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_DdmO9pD3xa9XTPNJ32zg2hcA","type":"function","function":{"name":"get_weather","arguments":""}}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\""}}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"location"}}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\":\""}}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"Paris"}}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":","}}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":" France"}}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"}"}}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"tool_calls"}]}

    data: [DONE]

    """#

  /// Assembled: the same call, later fragments spelled exactly like the SDK print
  /// (`"id": null, "type": null, "name": null`). Parsers must not let a null overwrite the id,
  /// type or name of the first fragment.
  static let chatCompletionsNullFragmentStream = #"""
    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index": 0, "id": "call_DdmO9pD3xa9XTPNJ32zg2hcA", "function": {"arguments": "", "name": "get_weather"}, "type": "function"}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index": 0, "id": null, "function": {"arguments": "{\"", "name": null}, "type": null}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index": 0, "id": null, "function": {"arguments": "location", "name": null}, "type": null}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index": 0, "id": null, "function": {"arguments": "\":\"", "name": null}, "type": null}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index": 0, "id": null, "function": {"arguments": "Paris", "name": null}, "type": null}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index": 0, "id": null, "function": {"arguments": ",", "name": null}, "type": null}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index": 0, "id": null, "function": {"arguments": " France", "name": null}, "type": null}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index": 0, "id": null, "function": {"arguments": "\"}", "name": null}, "type": null}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"tool_calls"}]}

    data: [DONE]

    """#

  /// Assembled: two parallel calls, told apart only by `index` (guide: "`index` Identifies
  /// which function call the delta is for"). Each call starts with its own first fragment.
  static let chatCompletionsParallelStream = #"""
    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_paris","type":"function","function":{"name":"get_weather","arguments":""}}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"location\":"}}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Paris, France\"}"}}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_london","type":"function","function":{"name":"get_weather","arguments":""}}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{\"location\":"}}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"\"London, UK\"}"}}]},"logprobs":null,"finish_reason":null}]}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"tool_calls"}]}

    data: [DONE]

    """#

  /// Assembled from the guide's "Send results back to model" (Ruby symbols written as JSON
  /// strings): the assistant message echoing `tool_calls` (arguments stay a JSON string), then
  /// one `role: "tool"` message per call, keyed by `tool_call_id`, `content` a string.
  static let chatCompletionsFollowUpMessages = #"""
    [
      {
        "role": "user",
        "content": "What is the weather in Paris?"
      },
      {
        "role": "assistant",
        "tool_calls": [
          {
            "id": "call_weather",
            "type": "function",
            "function": {
              "name": "get_weather",
              "arguments": "{\"city\":\"Paris\"}"
            }
          }
        ]
      },
      {
        "role": "tool",
        "tool_call_id": "call_weather",
        "content": "{\"city\":\"Paris\",\"temperature_c\":18}"
      }
    ]
    """#

  // MARK: - Responses API (OpenAI)
  //
  // Sources, accessed 2026-10-19:
  // - https://developers.openai.com/api/docs/guides/function-calling.md (Responses mode)
  // - https://developers.openai.com/api/reference/resources/responses/streaming-events.md
  // - https://developers.openai.com/api/reference/resources/responses/methods/create.md
  // - https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference.md
  // - https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations.md
  //
  // Verbatim in the docs: the guide's function-call events as bare JSON lines (kept below as
  // `responsesGuideEventLines`), the `event:`/`data:` framing with event name == data `type`
  // (create.md text example only), and the end of the stream at `response.completed` with no
  // `data: [DONE]`. NOT DOCUMENTED verbatim: framed function-call events, and a
  // `response.completed` whose output holds a function_call item; both are assembled here.
  //
  // The guide's events carry `response_id` and no `sequence_number`; the reference's carry
  // `sequence_number` and no `response_id`. The framed stream below carries both; parsers must
  // require neither. Argument deltas key on `item_id` (the item's `id`, "fc_..."); the
  // follow-up `function_call_output` keys on `call_id` ("call_...").
  //
  // ChatGPT-plan route (Sign in with ChatGPT, POST https://api.openai.com/v1/responses with
  // `Authorization: Bearer <ACCESS_TOKEN>`), constraints for phase 8:
  // - `store: false` and `stream: true` on every request; consume the event stream;
  // - omit `previous_response_id`, send the needed history in `input` every time;
  // - no `{type: "message", role: "system"}` items; use `instructions` or developer messages;
  // - group function tools in a `namespace` (or `additional_tools` input items);
  // - success only after `response.completed`; usage limits can arrive mid-stream as
  //   `response.failed` with `subscription_sharing_usage_limit_exceeded` or
  //   `subscription_sharing_usage_unavailable`;
  // - GET /v1/models there returns `models[]` with slug/display_name/visibility, not `data[]`.
  // Function-call streaming on this route is NOT DOCUMENTED (only a text-delta loop is shown),
  // nor whether its events differ from the public Responses events.

  /// Verbatim (guide, "Defining functions"): one entry of the request's `tools` array.
  /// Responses tools are flat (no nested `function` object, unlike Chat Completions).
  static let responsesFunctionTool = #"""
    {
      "type": "function",
      "name": "get_weather",
      "description": "Retrieves current weather for the given location.",
      "parameters": {
        "type": "object",
        "properties": {
          "location": {
            "type": "string",
            "description": "City and country e.g. Bogotá, Colombia"
          },
          "units": {
            "type": "string",
            "enum": ["celsius", "fahrenheit"],
            "description": "Units the temperature will be returned in."
          }
        },
        "required": ["location", "units"],
        "additionalProperties": false
      },
      "strict": true
    }
    """#

  /// Verbatim (guide, "Defining namespaces"), the second tool ("list_open_orders",
  /// `"defer_loading": true`) left out. The ChatGPT-plan route wants function tools grouped so.
  static let responsesNamespaceTool = #"""
    {
      "type": "namespace",
      "name": "crm",
      "description": "CRM tools for customer lookup and order management.",
      "tools": [
        {
          "type": "function",
          "name": "get_customer_profile",
          "description": "Fetch a customer profile by customer ID.",
          "parameters": {
            "type": "object",
            "properties": {
              "customer_id": { "type": "string" }
            },
            "required": ["customer_id"],
            "additionalProperties": false
          }
        }
      ]
    }
    """#

  /// Verbatim (guide, "Streaming" > "Output events"): the events as the guide prints them,
  /// one JSON object per line, no SSE framing, `response_id` but no `sequence_number`.
  static let responsesGuideEventLines = #"""
    {"type":"response.output_item.added","response_id":"resp_1234xyz","output_index":0,"item":{"type":"function_call","id":"fc_1234xyz","call_id":"call_1234xyz","name":"get_weather","arguments":""}}
    {"type":"response.function_call_arguments.delta","response_id":"resp_1234xyz","item_id":"fc_1234xyz","output_index":0,"delta":"{\""}
    {"type":"response.function_call_arguments.delta","response_id":"resp_1234xyz","item_id":"fc_1234xyz","output_index":0,"delta":"location"}
    {"type":"response.function_call_arguments.delta","response_id":"resp_1234xyz","item_id":"fc_1234xyz","output_index":0,"delta":"\":\""}
    {"type":"response.function_call_arguments.delta","response_id":"resp_1234xyz","item_id":"fc_1234xyz","output_index":0,"delta":"Paris"}
    {"type":"response.function_call_arguments.delta","response_id":"resp_1234xyz","item_id":"fc_1234xyz","output_index":0,"delta":","}
    {"type":"response.function_call_arguments.delta","response_id":"resp_1234xyz","item_id":"fc_1234xyz","output_index":0,"delta":" France"}
    {"type":"response.function_call_arguments.delta","response_id":"resp_1234xyz","item_id":"fc_1234xyz","output_index":0,"delta":"\"}"}
    {"type":"response.function_call_arguments.done","response_id":"resp_1234xyz","item_id":"fc_1234xyz","output_index":0,"arguments":"{\"location\":\"Paris, France\"}"}
    {"type":"response.output_item.done","response_id":"resp_1234xyz","output_index":0,"item":{"type":"function_call","id":"fc_1234xyz","call_id":"call_1234xyz","name":"get_weather","arguments":"{\"location\":\"Paris, France\"}"}}
    """#

  /// Assembled: the guide's events in the create.md `event:`/`data:` framing, plus a
  /// `sequence_number` (reference schema; 0 and 1, response.created and response.in_progress,
  /// left out), and a `response.completed` built from the create.md completed event with the
  /// create.md function_call output item shape. No `data: [DONE]` follows.
  static let responsesFunctionCallStream = #"""
    event: response.output_item.added
    data: {"type":"response.output_item.added","response_id":"resp_1234xyz","output_index":0,"item":{"type":"function_call","id":"fc_1234xyz","call_id":"call_1234xyz","name":"get_weather","arguments":""},"sequence_number":2}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","response_id":"resp_1234xyz","item_id":"fc_1234xyz","output_index":0,"delta":"{\"","sequence_number":3}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","response_id":"resp_1234xyz","item_id":"fc_1234xyz","output_index":0,"delta":"location","sequence_number":4}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","response_id":"resp_1234xyz","item_id":"fc_1234xyz","output_index":0,"delta":"\":\"","sequence_number":5}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","response_id":"resp_1234xyz","item_id":"fc_1234xyz","output_index":0,"delta":"Paris","sequence_number":6}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","response_id":"resp_1234xyz","item_id":"fc_1234xyz","output_index":0,"delta":",","sequence_number":7}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","response_id":"resp_1234xyz","item_id":"fc_1234xyz","output_index":0,"delta":" France","sequence_number":8}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","response_id":"resp_1234xyz","item_id":"fc_1234xyz","output_index":0,"delta":"\"}","sequence_number":9}

    event: response.function_call_arguments.done
    data: {"type":"response.function_call_arguments.done","response_id":"resp_1234xyz","item_id":"fc_1234xyz","output_index":0,"arguments":"{\"location\":\"Paris, France\"}","sequence_number":10}

    event: response.output_item.done
    data: {"type":"response.output_item.done","response_id":"resp_1234xyz","output_index":0,"item":{"type":"function_call","id":"fc_1234xyz","call_id":"call_1234xyz","name":"get_weather","arguments":"{\"location\":\"Paris, France\"}","status":"completed"},"sequence_number":11}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_1234xyz","object":"response","created_at":1741290958,"status":"completed","output":[{"type":"function_call","id":"fc_1234xyz","call_id":"call_1234xyz","name":"get_weather","arguments":"{\"location\":\"Paris, France\"}","status":"completed"}],"usage":{"input_tokens":37,"output_tokens":11,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":48,"input_tokens_details":{"cached_tokens":0}}},"sequence_number":12}

    """#

  /// Assembled from the guide's "Handling function calls": the next request's `input` echoes
  /// the function_call item (`input_messages += response.output`), then a
  /// `function_call_output` item keyed by `call_id`, `output` a string.
  static let responsesFollowUpInput = #"""
    [
      {
        "role": "user",
        "content": "What's the weather like in Paris today?"
      },
      {
        "type": "function_call",
        "id": "fc_1234xyz",
        "call_id": "call_1234xyz",
        "name": "get_weather",
        "arguments": "{\"location\":\"Paris, France\"}"
      },
      {
        "type": "function_call_output",
        "call_id": "call_1234xyz",
        "output": "{\"temperature_c\":18}"
      }
    ]
    """#

  // MARK: - Gemini API (generateContent / streamGenerateContent?alt=sse)
  //
  // Sources, accessed 2026-10-19:
  // - https://ai.google.dev/gemini-api/docs/migrate-to-interactions ("Before (generateContent)")
  // - https://ai.google.dev/api/generate-content
  // - https://ai.google.dev/api/models
  // - https://ai.google.dev/gemini-api/docs/thinking
  // - https://cloud.google.com/vertex-ai/generative-ai/docs/thought-signatures (Vertex AI docs)
  // (https://ai.google.dev/gemini-api/docs/function-calling now documents only the Interactions
  // API, so nothing is taken from it.)
  //
  // Verbatim in the docs: the tools request and auth header, and the streamed function call as
  // one bare JSON chunk ("streaming function calls arrived complete in a single chunk"). NOT
  // DOCUMENTED verbatim, so assembled from the API reference schemas: the `data: ` framing of
  // `alt=sse` (the curl samples show no response), `thoughtSignature` on a streamed functionCall
  // part, `finishReason` next to a function call, and a models.list response. A successful
  // function call ends with finishReason "STOP"; the tool finish reasons
  // (MALFORMED_FUNCTION_CALL, UNEXPECTED_TOOL_CALL, TOO_MANY_TOOL_CALLS) are errors.
  //
  // Thought signatures: the Gemini thinking guide only says signatures "can be attached to any
  // part, such as living inside `functionCall` parts or the final part of a response"; Part
  // schema: an opaque base64 string. The detailed rules come from the Vertex AI docs: with
  // parallel calls only the first functionCall part carries it, with sequential steps each
  // does; the part must be sent back unchanged, inside its original part (never merged); a
  // missing one on the first functionCall of a step is a 400 (finish reason
  // MISSING_THOUGHT_SIGNATURE exists in the API reference); without a functionCall it may sit on
  // the last part, even one with empty text, so read every part until finishReason.
  // The signature values below are placeholders, not real signatures.

  /// The Gemini API key header (`x-goog-api-key: $GEMINI_API_KEY` in the migration doc's REST
  /// samples; the API reference samples use `?key=` instead).
  static let geminiAPIKeyHeader = "x-goog-api-key"

  /// Verbatim (migration doc, "Function calling" > Before > REST): a generateContent request
  /// with `tools: [{functionDeclarations: [...]}]`. The API reference shell samples spell it
  /// `function_declarations`; both are in Google's docs.
  static let geminiToolsRequest = #"""
    {
        "contents": [{
            "parts": [{
                "text": "What is the weather like in Boston, MA?"
            }]
        }],
        "tools": [{
            "functionDeclarations": [{
                "name": "get_weather",
                "description": "Get the current weather",
                "parameters": {
                    "type": "OBJECT",
                    "properties": {
                        "location": {"type": "STRING"}
                    },
                    "required": ["location"]
                }
            }]
        }]
    }
    """#

  /// Assembled: the migration doc's verbatim stream chunk (`{"candidates": [{"content":
  /// {"parts": [{"functionCall": ...}]}}]}`) behind `data: `, with the response fields of the
  /// non-streamed sample (`"role": "model"`, `"finishReason": "STOP"`, `"index": 0`) and a
  /// `thoughtSignature` on the functionCall part. The call (name + args object) is whole.
  static let geminiFunctionCallStream = #"""
    data: {"candidates": [{"content": {"parts": [{"functionCall": {"name": "get_weather", "args": {"location": "Boston, MA"}}, "thoughtSignature": "ZGJsb3JlLXNwaWtlLW9wYXF1ZS10aG91Z2h0LXNpZ25hdHVyZQ=="}], "role": "model"}, "finishReason": "STOP", "index": 0}], "usageMetadata": {"promptTokenCount": 24, "candidatesTokenCount": 16, "totalTokenCount": 40}, "modelVersion": "gemini-2.5-flash-lite", "responseId": "spike-response-1"}

    """#

  /// Assembled: parallel calls in one chunk; the parts are the Vertex AI parallel example
  /// verbatim (only the first functionCall part carries `thoughtSignature`).
  static let geminiParallelCallsStream = #"""
    data: {"candidates": [{"content": {"parts": [{"functionCall": {"name": "get_current_temperature", "args": {"location": "Paris"}}, "thoughtSignature": "<SIGNATURE_A>"}, {"functionCall": {"name": "get_current_temperature", "args": {"location": "London"}}}], "role": "model"}, "finishReason": "STOP", "index": 0}]}

    """#

  /// Assembled from the Vertex AI rule: without a functionCall the signature may come last, on
  /// a part with empty text, in the chunk that carries `finishReason`.
  static let geminiTextSignatureStream = #"""
    data: {"candidates": [{"content": {"parts": [{"text": "It is sunny in Boston."}], "role": "model"}, "index": 0}]}

    data: {"candidates": [{"content": {"parts": [{"text": "", "thoughtSignature": "c2lnbmF0dXJlLW9uLWxhc3QtcGFydA=="}], "role": "model"}, "finishReason": "STOP", "index": 0}]}

    """#

  /// Assembled from the migration doc's JS follow-up: the model turn echoed unchanged
  /// (`response.candidates[0].content`, signature included), then the functionResponse
  /// `{name, response}` in a `"role": "user"` content. The docs disagree: Tool prose says role
  /// "function", Content.role ("Must be either 'user' or 'model'") and every example say "user".
  static let geminiFollowUpRequest = #"""
    {
      "contents": [
        {"role": "user", "parts": [{"text": "What is the weather like in Boston, MA?"}]},
        {"role": "model", "parts": [{"functionCall": {"name": "get_weather", "args": {"location": "Boston, MA"}}, "thoughtSignature": "ZGJsb3JlLXNwaWtlLW9wYXF1ZS10aG91Z2h0LXNpZ25hdHVyZQ=="}]},
        {"role": "user", "parts": [{"functionResponse": {"name": "get_weather", "response": {"result": {"temperature": 15, "unit": "celsius"}}}}]}
      ],
      "tools": [{"functionDeclarations": [{"name": "get_weather", "description": "Get the current weather", "parameters": {"type": "OBJECT", "properties": {"location": {"type": "STRING"}}, "required": ["location"]}}]}]
    }
    """#

  /// Assembled from the API reference Model / ListModelsResponse schemas (no example response
  /// is documented). `name` is `models/{model}`; `nextPageToken` is omitted on the last page.
  static let geminiModelsListResponse = #"""
    {
      "models": [
        {
          "name": "models/gemini-2.5-flash-lite",
          "version": "001",
          "displayName": "Gemini 2.5 Flash-Lite",
          "description": "A fast, low-cost model.",
          "inputTokenLimit": 1048576,
          "outputTokenLimit": 65536,
          "supportedGenerationMethods": ["generateContent", "countTokens", "createCachedContent"],
          "thinking": true,
          "temperature": 1,
          "maxTemperature": 2,
          "topP": 0.95,
          "topK": 64
        },
        {
          "name": "models/text-embedding-004",
          "version": "004",
          "displayName": "Text Embedding 004",
          "inputTokenLimit": 2048,
          "outputTokenLimit": 1,
          "supportedGenerationMethods": ["embedContent"]
        }
      ],
      "nextPageToken": "spike-next-page"
    }
    """#
}
