%%% @doc Private transport and public response adapter for AndEE inference.
-module(lib_andee_inference).
-export([completions/3, models/3, health/3, v1/3]).

-define(INFERENCE_SOCKET_ENV, "ANDEE_INFERENCE_SOCKET").
-define(PROTOCOL, <<"andee-inference-local@1">>).
-define(DEFAULT_TIMEOUT_MS, 600_000).
-define(MAX_FRAME_BYTES, 16 * 1024 * 1024).
-define(INFERENCE_PARAM_KEYS, [
    <<"model">>, <<"prompt">>, <<"messages">>, <<"max_tokens">>,
    <<"max_completion_tokens">>, <<"temperature">>, <<"top_p">>, <<"n">>,
    <<"stream">>, <<"stop">>, <<"presence_penalty">>, <<"frequency_penalty">>,
    <<"logit_bias">>, <<"user">>, <<"seed">>, <<"top_k">>, <<"reasoning">>,
    <<"reasoning_effort">>, <<"thinking">>, <<"repetition_penalty">>,
    <<"length_penalty">>, <<"early_stopping">>, <<"tools">>, <<"tool_choice">>,
    <<"tee">>
]).

completions(Base, Req, Opts) ->
    Payload0 = request_payload(Req, Opts),
    Payload = case {
        maps:is_key(<<"tee">>, Payload0),
        maps:get(<<"tee">>, request_view(Req, Opts), undefined)
    } of
        {false, Tee} when Tee =/= undefined -> Payload0#{ <<"tee">> => Tee };
        _ -> Payload0
    end,
    case normalize_boolean(maps:get(<<"stream">>, Payload, false), false) of
        true ->
            format_response(
                {error, 400, <<"Streaming is not supported by andee-inference@1.0">>},
                Req,
                Opts
            );
        false ->
            Model = first_defined([
                maps:get(<<"model">>, Payload, undefined),
                config_value(<<"inference-model">>, Base, Req, Opts)
            ]),
            Provider = provider_id(Base, Req, Opts),
            case Model of
                undefined ->
                    format_response(
                        {error, 400, <<"An inference model is required">>},
                        Req,
                        Opts
                    );
                _ ->
                    Request = provider_request(
                        completion_request(Payload, Model),
                        Provider
                    ),
                    ObservedPayload = Payload#{ <<"model">> => Model },
                    notify_inference_observer(
                        Provider,
                        Model,
                        ObservedPayload,
                        Opts
                    ),
                    format_response(
                        request(Request, ?DEFAULT_TIMEOUT_MS),
                        Req,
                        Opts
                    )
            end
    end.

completion_request(Payload, undefined) ->
    #{
        <<"action">> => <<"completions">>,
        <<"payload">> => Payload
    };
completion_request(Payload, Model) ->
    (completion_request(Payload, undefined))#{ <<"model">> => Model }.

models(Base, Req, Opts) ->
    format_response(
        request(
            provider_request(
                #{ <<"action">> => <<"models">> },
                provider_id(Base, Req, Opts)
            ),
            30000
        ),
        Req,
        Opts
    ).

health(Base, Req, Opts) ->
    format_response(
        request(
            provider_request(
                #{ <<"action">> => <<"health">> },
                provider_id(Base, Req, Opts)
            ),
            30000
        ),
        Req,
        Opts
    ).

v1(Base, Req, Opts) ->
    {ok,
        hb_util:deep_merge(
            hb_message:uncommitted(Base, Opts),
            (hb_message:uncommitted(Req, Opts))#{
                <<"device">> => <<"andee-inference@1.0">>
            },
            Opts
        )}.

request_payload(Req, Opts) ->
    View = request_view(Req, Opts),
    case maps:get(<<"body">>, View, not_found) of
        Body when is_map(Body) -> strip_ao_metadata(Body);
        Body when is_binary(Body) ->
            try strip_ao_metadata(hb_json:decode(Body)) of
                Decoded when is_map(Decoded) -> Decoded;
                _ -> maps:with(?INFERENCE_PARAM_KEYS, View)
            catch
                _:_ -> maps:with(?INFERENCE_PARAM_KEYS, View)
            end;
        _ ->
            maps:with(?INFERENCE_PARAM_KEYS, View)
    end.

request_view(Value, Opts) when is_map(Value) ->
    hb_message:uncommitted(Value, Opts);
request_view(_Value, _Opts) ->
    #{}.

config_value(Key, Base, Req, Opts) ->
    ReqView = request_view(Req, Opts),
    BaseView = request_view(Base, Opts),
    first_defined([
        maps:get(Key, ReqView, undefined),
        maps:get(Key, BaseView, undefined),
        maps:get(Key, Opts, undefined)
    ]).

first_defined([]) ->
    undefined;
first_defined([Value | Rest])
        when Value =:= undefined; Value =:= false; Value =:= <<>>; Value =:= "" ->
    first_defined(Rest);
first_defined([Value | _Rest]) ->
    Value.

provider_id(Base, Req, Opts) ->
    first_defined([
        config_value(<<"inference-provider">>, Base, Req, Opts),
        config_value(<<"provider-id">>, Base, Req, Opts)
    ]).

provider_request(Request, undefined) ->
    Request;
provider_request(Request, Provider) ->
    Request#{ <<"provider">> => Provider }.

notify_inference_observer(Provider, Model, Payload, Opts) ->
    case maps:get(<<"inference-observer-fun">>, Opts, undefined) of
        Fun when is_function(Fun, 1) ->
            Event = #{
                <<"provider">> => Provider,
                <<"api">> => <<"openai-chat">>,
                <<"model">> => Model,
                <<"base-url">> => <<"andee://local">>,
                <<"path">> => <<"/v1/chat/completions">>,
                <<"body">> => iolist_to_binary(hb_json:encode(Payload)),
                <<"payload">> => Payload
            },
            try Fun(Event) of
                _ -> ok
            catch
                _:_ -> ok
            end;
        _ ->
            ok
    end.

normalize_boolean(true, _Default) -> true;
normalize_boolean(false, _Default) -> false;
normalize_boolean(<<"true">>, _Default) -> true;
normalize_boolean(<<"false">>, _Default) -> false;
normalize_boolean(1, _Default) -> true;
normalize_boolean(0, _Default) -> false;
normalize_boolean(_, Default) -> Default.

strip_ao_metadata(Map) when is_map(Map) ->
    maps:from_list(
        [
            {strip_ao_metadata(Key), strip_ao_metadata(Value)}
         || {Key, Value} <- maps:to_list(Map),
            not provider_metadata_key(Key)
        ]
    );
strip_ao_metadata(List) when is_list(List) ->
    [strip_ao_metadata(Value) || Value <- List];
strip_ao_metadata(Value) ->
    Value.

provider_metadata_key(<<"commitments">>) -> true;
provider_metadata_key(commitments) -> true;
provider_metadata_key(<<"ao-types">>) -> true;
provider_metadata_key('ao-types') -> true;
provider_metadata_key(_) -> false.

request(Message, Timeout) ->
    case os:getenv(?INFERENCE_SOCKET_ENV) of
        false -> {error, 503, <<"AndEE inference runtime is unavailable">>};
        [] -> {error, 503, <<"AndEE inference runtime is unavailable">>};
        SocketPath ->
            request_socket(
                SocketPath,
                Message#{ <<"protocol">> => ?PROTOCOL },
                Timeout
            )
    end.

request_socket(SocketPath, Message, Timeout) ->
    try
        {ok, Socket} = gen_tcp:connect(
            {local, SocketPath},
            0,
            [
                binary,
                {active, false},
                {packet, 4},
                {packet_size, ?MAX_FRAME_BYTES}
            ],
            Timeout
        ),
        try
            ok = gen_tcp:send(Socket, iolist_to_binary(hb_json:encode(Message))),
            receive_response(Socket, Timeout)
        after
            gen_tcp:close(Socket)
        end
    catch
        _Class:_Failure ->
            {error, 503, <<"AndEE inference runtime is unavailable">>}
    end.

receive_response(Socket, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Bin} ->
            try response(hb_json:decode(Bin))
            catch
                _:_ -> {error, 500, <<"Invalid AndEE inference response">>}
            end;
        {error, timeout} ->
            {error, 408, <<"Inference timed out">>};
        {error, _Reason} ->
            {error, 503, <<"AndEE inference runtime is unavailable">>}
    end.

response(#{ <<"ok">> := true, <<"body">> := Body }) ->
    {ok, Body};
response(Response = #{ <<"status">> := Status, <<"error">> := Error })
        when is_integer(Status), is_binary(Error) ->
    {error, Status, maps:without([<<"ok">>, <<"status">>], Response)};
response(_) ->
    {error, 500, <<"Invalid AndEE inference response">>}.

format_response({ok, Body}, Req, Opts) when is_map(Body) ->
    Encoded = hb_json:encode(Body),
    typed_response(ok, Req, Encoded, <<"Inference-Response">>, #{
        <<"status">> => 200,
        <<"content-type">> => <<"application/json">>,
        <<"body">> => Encoded
    }, Opts);
format_response({error, Status, Error}, Req, Opts) when is_map(Error) ->
    Message = maps:get(<<"error">>, Error, <<"Inference failed">>),
    Body = hb_json:encode(Error),
    typed_response(error, Req, Body, <<"Inference-Error">>, #{
        <<"status">> => Status,
        <<"message">> => Message,
        <<"body">> => Body
    }, Opts);
format_response({error, Status, Message}, Req, Opts) when is_binary(Message) ->
    Body = hb_json:encode(#{ <<"error">> => Message }),
    typed_response(error, Req, Body, <<"Inference-Error">>, #{
        <<"status">> => Status,
        <<"message">> => Message,
        <<"body">> => Body
    }, Opts).

typed_response(Tag, Req, Body, Action, HttpResponse, Opts) ->
    case maps:get(<<"type">>, request_view(Req, Opts), not_found) of
        <<"Message">> -> {Tag, #{ <<"data">> => Body, <<"action">> => Action }};
        _ -> {Tag, HttpResponse}
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

local_transport_round_trip_test() ->
    Path = filename:join(
        "/tmp",
        "andee-inference-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    file:delete(Path),
    {ok, Listener} = gen_tcp:listen(
        0,
        [
            binary,
            {active, false},
            {packet, 4},
            {packet_size, ?MAX_FRAME_BYTES},
            {ifaddr, {local, Path}}
        ]
    ),
    Parent = self(),
    Server = spawn(fun() ->
        {ok, Socket} = gen_tcp:accept(Listener),
        {ok, EncodedRequest} = gen_tcp:recv(Socket, 0, 1000),
        Parent ! {inference_request, hb_json:decode(EncodedRequest)},
        ok = gen_tcp:send(
            Socket,
            iolist_to_binary(hb_json:encode(#{
                <<"ok">> => true,
                <<"body">> => #{ <<"status">> => <<"healthy">> }
            }))
        ),
        gen_tcp:close(Socket)
    end),
    try
        ?assertEqual(
            {ok, #{ <<"status">> => <<"healthy">> }},
            request_socket(
                Path,
                #{ <<"protocol">> => ?PROTOCOL, <<"action">> => <<"health">> },
                1000
            )
        ),
        receive
            {inference_request, Request} ->
                ?assertEqual(?PROTOCOL, maps:get(<<"protocol">>, Request))
        after 1000 ->
            ?assert(false)
        end
    after
        catch exit(Server, kill),
        gen_tcp:close(Listener),
        file:delete(Path)
    end.

request_payload_strips_ao_metadata_test() ->
    Payload = request_payload(#{ <<"body">> => #{
        <<"messages">> => [#{
            <<"role">> => <<"user">>,
            <<"content">> => <<"hello">>,
            <<"commitments">> => #{ <<"signature">> => #{} }
        }],
        <<"ao-types">> => <<"temperature=\"float\"">>
    } }, #{}),
    ?assertNot(maps:is_key(<<"ao-types">>, Payload)),
    [Message] = maps:get(<<"messages">>, Payload),
    ?assertNot(maps:is_key(<<"commitments">>, Message)).

streaming_is_rejected_test() ->
    {error, Response} = completions(
        #{},
        #{ <<"body">> => #{ <<"stream">> => true } },
        #{}
    ),
    ?assertEqual(400, maps:get(<<"status">>, Response)).

missing_model_is_not_serialized_as_undefined_test() ->
    Request = completion_request(#{ <<"prompt">> => <<"hello">> }, undefined),
    ?assertNot(maps:is_key(<<"model">>, Request)).

public_completion_requires_a_model_test() ->
    {error, Response} = completions(
        #{},
        #{ <<"body">> => #{ <<"prompt">> => <<"hello">> } },
        #{}
    ),
    ?assertEqual(400, maps:get(<<"status">>, Response)).

inference_observer_receives_provider_payload_before_transport_test() ->
    Parent = self(),
    Observer = fun(Event) -> Parent ! {inference_observer, Event} end,
    {error, _} = completions(
        #{ <<"inference-provider">> => <<"local-andee">> },
        #{ <<"body">> => #{
            <<"model">> => <<"local/test-model">>,
            <<"messages">> => [#{
                <<"role">> => <<"user">>,
                <<"content">> => <<"hello">>
            }]
        } },
        #{ <<"inference-observer-fun">> => Observer }
    ),
    receive
        {inference_observer, Event} ->
            ?assertEqual(<<"local-andee">>, maps:get(<<"provider">>, Event)),
            ?assertEqual(<<"openai-chat">>, maps:get(<<"api">>, Event)),
            ?assertEqual(
                <<"local/test-model">>,
                maps:get(<<"model">>, maps:get(<<"payload">>, Event))
            ),
            ?assert(is_binary(maps:get(<<"body">>, Event)))
    after 1000 ->
        ?assert(false)
    end.

configured_model_is_inserted_into_observed_payload_test() ->
    Parent = self(),
    Observer = fun(Event) -> Parent ! {configured_model_observer, Event} end,
    {error, _} = completions(
        #{ <<"inference-model">> => <<"local/configured-model">> },
        #{ <<"body">> => #{ <<"prompt">> => <<"hello">> } },
        #{ <<"inference-observer-fun">> => Observer }
    ),
    receive
        {configured_model_observer, Event} ->
            ?assertEqual(
                <<"local/configured-model">>,
                maps:get(<<"model">>, maps:get(<<"payload">>, Event))
            ),
            ?assertEqual(
                <<"local/configured-model">>,
                maps:get(<<"model">>, hb_json:decode(maps:get(<<"body">>, Event)))
            )
    after 1000 ->
        ?assert(false)
    end.

broker_error_details_are_preserved_test() ->
    Error = #{
        <<"ok">> => false,
        <<"status">> => 503,
        <<"error">> => <<"backend-initialization-failed">>,
        <<"backend">> => <<"npu">>,
        <<"model">> => <<"gemma">>
    },
    {error, 503, PublicError} = response(Error),
    ?assertEqual(<<"npu">>, maps:get(<<"backend">>, PublicError)),
    ?assertEqual(<<"gemma">>, maps:get(<<"model">>, PublicError)),
    ?assertNot(maps:is_key(<<"ok">>, PublicError)),
    ?assertNot(maps:is_key(<<"status">>, PublicError)).

-endif.
