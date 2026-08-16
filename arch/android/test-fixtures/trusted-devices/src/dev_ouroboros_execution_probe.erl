%%% @doc Runtime acceptance adapter for Ouroboros' execution client.
%%%
%%% The package captures the real application-owned client and tool-name
%%% modules from the separately supplied Ouroboros checkout. It is never part
%%% of the Android staging or APK build graph.
-module(dev_ouroboros_execution_probe).
-implements(<<"ouroboros-execution-probe@1.0">>).
-specification("../docs/ouroboros-execution-probe.md").
-device_libraries([
    lib_ouroboros_execution_client,
    lib_ouroboros_execution_tools,
    lib_ouroboros_attachment,
    lib_ouroboros_attachments,
    lib_ouroboros_utils
]).
-export([info/1, index/3, run/3]).

info(_) ->
    #{
        <<"index">> => fun index/3,
        <<"run">> => fun run/3
    }.

index(_Base, _Req, Opts) ->
    {ok,
        #{
            <<"device">> => <<"ouroboros-execution-probe@1.0">>,
            <<"execution-device">> => lib_ouroboros_execution_client:device(Opts),
            <<"status">> => <<"ready">>
        }}.

run(_Base, Req, Opts) ->
    Body = hb_maps:get(<<"body">>, Req, Req, Opts),
    Member = hb_maps:get(<<"member-id">>, Body, <<"ouroboros-runtime-consumer">>, Opts),
    Path = <<"/root/", Member/binary, "/application-probe.txt">>,
    ok =
        lib_ouroboros_execution_client:write_file(
            Member,
            Path,
            <<"application-">>,
            Opts
        ),
    {ok, <<>>, 0} =
        lib_ouroboros_execution_client:exec(
            Member,
            <<"/root">>,
            <<"printf client >> ", Path/binary>>,
            5000,
            true,
            Opts
        ),
    {ok, Content} =
        lib_ouroboros_execution_client:read_file(Member, Path, Opts),
    {ok, [DirectAttachment]} =
        lib_ouroboros_attachment:prepare_paths(
            Member,
            [#{ <<"path">> => Path }],
            Opts
        ),
    Content = hb_util:decode(maps:get(<<"data">>, DirectAttachment)),
    {ok, [Archive]} =
        lib_ouroboros_attachment:prepare_paths(
            Member,
            [
                #{
                    <<"path">> => <<"/root/", Member/binary>>,
                    <<"name">> => <<"probe-archive">>
                }
            ],
            Opts
        ),
    <<"tar.gz">> = maps:get(<<"archive-format">>, Archive),
    {ok, [SavedArchive]} =
        lib_ouroboros_attachment:save_attachments(
            Member,
            <<"runtime-probe">>,
            [Archive],
            Opts
        ),
    {ok, Content} =
        lib_ouroboros_execution_client:read_file(
            Member,
            <<"/root/inbox/runtime-probe/", Member/binary, "/application-probe.txt">>,
            Opts
        ),
    {ok,
        #{
            <<"device">> => <<"ouroboros-execution-probe@1.0">>,
            <<"execution-device">> => lib_ouroboros_execution_client:device(Opts),
            <<"member-id">> => Member,
            <<"content">> => Content,
            <<"direct-attachment-bytes">> => maps:get(<<"size">>, DirectAttachment),
            <<"archive-format">> => maps:get(<<"archive-format">>, Archive),
            <<"archive-saved-path">> => maps:get(<<"saved-path">>, SavedArchive),
            <<"ok">> => true,
            <<"status">> => 200
        }}.
