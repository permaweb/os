%%% @doc AndEE local hardware inference device.
-module(dev_inference).
-implements(<<"inference@1.0">>).
-specification("../docs/device-specs/inference.md").
-device_libraries([lib_andee_inference]).
-export([info/1, completions/3, chat/3, models/3, health/3, v1/3]).

info(_) ->
    #{
        exports => [<<"completions">>, <<"chat">>, <<"models">>, <<"health">>, <<"v1">>],
        description => <<"AndEE local hardware inference device">>,
        version => <<"1.0">>
    }.

completions(Base, Req, Opts) ->
    lib_andee_inference:completions(Base, Req, Opts).

chat(Base, Req, Opts) ->
    completions(Base, Req, Opts).

models(Base, Req, Opts) ->
    lib_andee_inference:models(Base, Req, Opts).

health(Base, Req, Opts) ->
    lib_andee_inference:health(Base, Req, Opts).

v1(Base, Req, Opts) ->
    lib_andee_inference:v1(Base, Req, Opts).
