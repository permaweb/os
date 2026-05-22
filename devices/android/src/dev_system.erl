%%% @doc Minimal Android-oriented system report for HandEE measurements.
%%%
%%% The report intentionally describes only the app/runtime facts that can be
%%% bound into Android Keystore evidence. Hardware-rooted verdicts live in
%%% `~handee@1.0' evidence; this device supplies the AO-Core measurement body
%%% input used by `~measurement@1.0'.
-module(dev_system).
-implements(<<"system@1.0">>).
-export([info/1, info/3, all/3]).

-include("include/hb.hrl").

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
            <<"measurement-device">> => <<"handee@1.0">>
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
        <<"schema">> => <<"handee-system-report@1">>,
        <<"generated-at-unix">> => Now,
        <<"platform">> => <<"android">>,
        <<"runtime">> => runtime_report(Opts),
        <<"app">> => app_report(Opts),
        <<"policy">> => local_policy_report(Opts)
    }.

runtime_report(Opts) ->
    #{
        <<"hyperbeam-release">> =>
            hb_opts:get(<<"handee-hyperbeam-release">>, <<"unknown">>, Opts),
        <<"store">> => #{
            <<"default-module">> => <<"hb_store_volatile">>,
            <<"persistence">> => <<"volatile">>
        },
        <<"app-uid-isolation">> => true,
        <<"runtime-root">> =>
            hb_opts:get(<<"handee-runtime-root">>, <<"app-private">>, Opts),
        <<"config-source">> =>
            hb_opts:get(<<"handee-config-source">>, <<"app-private">>, Opts)
    }.

app_report(Opts) ->
    #{
        <<"package-name">> =>
            hb_opts:get(<<"handee-package-name">>,
                        <<"org.permaweb.handee">>,
                        Opts),
        <<"version-name">> =>
            hb_opts:get(<<"handee-version-name">>, <<"unknown">>, Opts),
        <<"version-code">> =>
            hb_opts:get(<<"handee-version-code">>, <<"unknown">>, Opts),
        <<"release-digest">> =>
            hb_opts:get(<<"handee-release-digest">>, <<"unknown">>, Opts)
    }.

local_policy_report(Opts) ->
    #{
        <<"policy-source">> => <<"android-agent">>,
        <<"debuggable">> =>
            hb_opts:get(<<"handee-debuggable">>, <<"unknown">>, Opts),
        <<"adb-enabled">> =>
            hb_opts:get(<<"handee-adb-enabled">>, <<"unknown">>, Opts),
        <<"debugger-attached">> =>
            hb_opts:get(<<"handee-debugger-attached">>, <<"unknown">>, Opts),
        <<"tracer-pid">> =>
            hb_opts:get(<<"handee-tracer-pid">>, <<"unknown">>, Opts)
    }.
