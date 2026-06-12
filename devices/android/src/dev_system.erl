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
        <<"app-uid-isolation">> => true,
        <<"runtime-root">> =>
            hb_opts:get(<<"andee-runtime-root">>, <<"app-private">>, Opts),
        <<"config-source">> =>
            hb_opts:get(<<"andee-config-source">>, <<"app-private">>, Opts),
        <<"android-abi">> =>
            hb_opts:get(<<"andee-android-abi">>, <<"unknown">>, Opts),
        <<"artifact-identity">> => #{
            <<"runtime-zip-sha256">> =>
                hb_opts:get(<<"andee-runtime-zip-sha256">>, <<"unknown">>, Opts),
            <<"native-launcher-sha256">> =>
                hb_opts:get(<<"andee-native-launcher-sha256">>, <<"unknown">>, Opts),
            <<"native-libraries-sha256">> =>
                hb_opts:get(<<"andee-native-libraries-sha256">>, <<"unknown">>, Opts)
        }
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
            hb_opts:get(<<"andee-release-digest">>, <<"unknown">>, Opts),
        <<"release-digest-kind">> =>
            <<"apk-signing-certificates-sha256-hex">>,
        <<"artifact-identity">> => #{
            <<"base-apk-sha256">> =>
                hb_opts:get(<<"andee-base-apk-sha256">>, <<"unknown">>, Opts),
            <<"apk-set-sha256">> =>
                hb_opts:get(<<"andee-apk-set-sha256">>, <<"unknown">>, Opts)
        }
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

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

report_exposes_artifact_identity_test() ->
    Report =
        report(#{
            <<"andee-runtime-zip-sha256">> => <<"runtime">>,
            <<"andee-native-launcher-sha256">> => <<"launcher">>,
            <<"andee-native-libraries-sha256">> => <<"libs">>,
            <<"andee-base-apk-sha256">> => <<"base">>,
            <<"andee-apk-set-sha256">> => <<"set">>
        }),
    Runtime = hb_maps:get(<<"runtime">>, Report),
    App = hb_maps:get(<<"app">>, Report),
    RuntimeArtifacts = hb_maps:get(<<"artifact-identity">>, Runtime),
    AppArtifacts = hb_maps:get(<<"artifact-identity">>, App),
    ?assertEqual(<<"runtime">>,
        hb_maps:get(<<"runtime-zip-sha256">>, RuntimeArtifacts)),
    ?assertEqual(<<"launcher">>,
        hb_maps:get(<<"native-launcher-sha256">>, RuntimeArtifacts)),
    ?assertEqual(<<"libs">>,
        hb_maps:get(<<"native-libraries-sha256">>, RuntimeArtifacts)),
    ?assertEqual(<<"base">>,
        hb_maps:get(<<"base-apk-sha256">>, AppArtifacts)),
    ?assertEqual(<<"set">>,
        hb_maps:get(<<"apk-set-sha256">>, AppArtifacts)).

-endif.
