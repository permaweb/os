%%% @doc Minimal Android-oriented system report for AndEE measurements.
%%%
%%% The report intentionally describes only the app/runtime facts that can be
%%% bound into Android Keystore evidence. Hardware-rooted verdicts live in
%%% `~andee@1.0' evidence; this device supplies the AO-Core measurement body
%%% input used by `~measurement@1.0'.
-module(dev_system).
-implements(<<"system@1.0">>).
-export([info/1, info/3, all/3]).

-include_lib("hb/include/hb.hrl").

info(_) ->
    #{
        exports => [
            <<"info">>,
            <<"all">>
        ]
    }.

info(_Base, _Req, _Opts) ->
    {ok, #{
        <<"status">> => 200,
        <<"body">> => #{
            <<"version">> => <<"1.0">>,
            <<"platform">> => <<"android">>,
            <<"measurement-device">> => <<"andee@1.0">>
        }
    }}.

all(_Base, _Req, Opts) ->
    {ok, #{
        <<"status">> => 200,
        <<"body">> => report(Opts)
    }}.

report(Opts) ->
    Now = erlang:system_time(second),
    #{
        <<"schema">> => <<"andee-system-report@1">>,
        <<"generated-at-unix">> => Now,
        <<"platform">> => <<"android">>,
        <<"runtime">> => runtime_report(Opts),
        <<"app">> => app_report(Opts),
        <<"policy">> => local_policy_report(Opts)
    }.

runtime_report(Opts) ->
    #{
        <<"hyperbeam-release">> =>
            hb_opts:get(<<"andee-hyperbeam-release">>, <<"unknown">>, Opts),
        <<"store">> => #{
            <<"default-module">> => <<"hb_store_volatile">>,
            <<"persistence">> => <<"volatile">>
        },
        <<"app-uid-isolation">> => true,
        <<"runtime-root">> =>
            hb_opts:get(<<"andee-runtime-root">>, <<"app-private">>, Opts),
        <<"config-source">> =>
            hb_opts:get(<<"andee-config-source">>, <<"app-private">>, Opts)
    }.

app_report(Opts) ->
    #{
        <<"package-name">> =>
            hb_opts:get(<<"andee-package-name">>,
                        <<"org.permaweb.andee">>,
                        Opts),
        <<"version-name">> =>
            hb_opts:get(<<"andee-version-name">>, <<"unknown">>, Opts),
        <<"version-code">> =>
            hb_opts:get(<<"andee-version-code">>, <<"unknown">>, Opts),
        <<"release-digest">> =>
            hb_opts:get(<<"andee-release-digest">>, <<"unknown">>, Opts)
    }.

local_policy_report(Opts) ->
    #{
        <<"policy-source">> => <<"android-agent">>,
        <<"debuggable">> =>
            hb_opts:get(<<"andee-debuggable">>, <<"unknown">>, Opts),
        <<"adb-enabled">> =>
            hb_opts:get(<<"andee-adb-enabled">>, <<"unknown">>, Opts),
        <<"debugger-attached">> =>
            hb_opts:get(<<"andee-debugger-attached">>, <<"unknown">>, Opts),
        <<"tracer-pid">> =>
            hb_opts:get(<<"andee-tracer-pid">>, <<"unknown">>, Opts)
    }.
