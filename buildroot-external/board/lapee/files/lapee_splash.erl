%% -*- erlang -*-
%%
%% lapee_splash -- LapEE 3D animated boot splash.
%%
%% Runs as its own BEAM VM, forked from init right after the basic
%% mounts. Owns /dev/console exclusively; renders a rotating wireframe
%% laptop with an easing-open lid at 12 fps, and prints a single
%% status line below it. The splash polls the phase machine itself --
%% init doesn't push state in.
%%
%%   boot     /run/lapee/primary-net not yet written  ("starting LapEE...")
%%   net-up   primary-net has an ip=, /info not yet 200
%%               ("network up; starting HyperBEAM...")
%%   hb-wait  /info still not 200 after the first probe
%%               ("starting HyperBEAM... <ip> (Ns)")
%%   ready    /info returned 200 ("Running at http://<ip>:8734/")
%%
%% The /info probe is a raw gen_tcp HTTP/1.0 round-trip rather than
%% an inets/httpc call -- the URL contains `~' and `@', which are
%% lawful per RFC 3986 but trip OTP 27's URL parser. gen_tcp removes
%% the dependency entirely.
%%
%% Compiled to a .beam at build time by build-initramfs-hb.sh and
%% loaded by init via:
%%
%%   erl -boot start_clean -pa /usr/local/lib/lapee-splash \
%%       /usr/lib/hyperbeam/lib/*/ebin -noshell -noinput \
%%       -run lapee_splash main

-module(lapee_splash).
-export([main/0, main/1]).

main()      -> main([]).

%% ============================================================
%% Constants
%% ============================================================
-define(FPS, 12).
-define(SLEEP_MS, 83).               %% ~1000/FPS
-define(POLL_TIMEOUT_MS, 500).
-define(MIN_W, 80).
-define(MIN_H, 24).
%% Lid open angle (radians). 1.85 ≈ 106°, classic working tilt.
-define(LID_TARGET, 1.85).
%% Lid easing per frame. Lower = slower open; 0.04 at 12 fps
%% reaches >95% of target after ~7 s.
-define(LID_EASE, 0.04).
%% Yaw advance per frame, radians. Constant for the whole splash
%% lifetime -- the spin never locks, so the laptop keeps gently
%% rotating with the URL underneath after HB is up.
-define(YAW_PER_FRAME, 0.05).

%% All paths/probe targets overridable via env so the same module
%% can be exercised from a dev box (LAPEE_CONSOLE=/tmp/out etc.).
console_path()     -> os:getenv("LAPEE_CONSOLE",     "/dev/console").
primary_net_path() -> os:getenv("LAPEE_PRIMARY_NET", "/run/lapee/primary-net").
probe_host()       -> os:getenv("LAPEE_PROBE_HOST",  "127.0.0.1").
probe_port()       -> list_to_integer(os:getenv("LAPEE_PROBE_PORT", "8734")).
probe_path()       -> os:getenv("LAPEE_PROBE_PATH",  "/~measurement@1.0/info").
log_path()         -> os:getenv("LAPEE_SPLASH_LOG",  "/run/lapee/splash.log").
status_path()      -> os:getenv("LAPEE_STATUS",      "/run/lapee/status").
provision_input_path() ->
    os:getenv("LAPEE_PROVISION_INPUT", "/run/lapee/sb-provision-input").
provision_mode_path() ->
    os:getenv("LAPEE_PROVISION_MODE", "/run/lapee/sb-provision-mode").
provision_report_path() ->
    os:getenv("LAPEE_PROVISION_REPORT", "/run/lapee/sb-provision-report").
provision_prompt_path() ->
    os:getenv("LAPEE_PROVISION_PROMPT", "/run/lapee/sb-provision-prompt").

splash_layout() ->
    case os:getenv("LAPEE_SPLASH_LAYOUT") of
        false -> blue;
        ""    -> blue;
        Str ->
            case string:lowercase(Str) of
                "blue"    -> blue;
                "provision" -> provision;
                _         -> blue
            end
    end.

%% Terminal dimensions detected at startup via `stty size'. On the
%% iron framebuffer console with -vga std + 8x16 font that's
%% typically 128x48, not 80x24. Hard-coding 80x24 leaves the splash
%% in the upper-left corner of a wider screen.
detect_dims() ->
    Cmd = io_lib:format("stty -F ~s size 2>/dev/null", [console_path()]),
    Out = string:trim(os:cmd(lists:flatten(Cmd))),
    SttyDims = case string:tokens(Out, " ") of
        [RowsStr, ColsStr] ->
            try
                Rows = list_to_integer(RowsStr),
                Cols = list_to_integer(ColsStr),
                {max(?MIN_W, Cols), max(?MIN_H, Rows)}
            catch _:_ -> {?MIN_W, ?MIN_H}
            end;
        _ -> {?MIN_W, ?MIN_H}
    end,
    fb_dims(SttyDims).

fb_dims(Default = {SttyW, SttyH}) ->
    case file:read_file("/sys/class/graphics/fb0/virtual_size") of
        {ok, Bin} ->
            case string:tokens(string:trim(binary_to_list(Bin)), ",") of
                [PxWStr, PxHStr] ->
                    try
                        PxW = list_to_integer(PxWStr),
                        PxH = list_to_integer(PxHStr),
                        %% fbcon usually uses an 8x16 font with
                        %% simpledrm/efifb. Some firmware paths leave
                        %% `stty size' stuck at 80x25, which makes the
                        %% splash occupy only the upper-left quadrant.
                        %% Prefer the larger inferred grid, while never
                        %% shrinking below the TTY-reported dimensions.
                        {max(SttyW, PxW div 8),
                         max(SttyH, PxH div 16)}
                    catch _:_ -> Default
                    end;
                _ -> Default
            end;
        _ -> Default
    end.

%% ============================================================
%% Entry point
%% ============================================================
main(_Args) ->
    log_start(),

    %% Detect actual terminal dimensions. The framebuffer console
    %% size depends on the EFI mode + chosen font; hard-coding 80x24
    %% would pin the splash to the upper-left of any wider screen.
    {Cols, Rows} = detect_dims(),
    log_event(io_lib:format("dims: ~bx~b", [Cols, Rows])),

    %% Open /dev/console raw. fbcon interprets ANSI escapes in-kernel.
    {ok, Out} = file:open(console_path(), [write, raw]),

    %% Hide cursor, clear screen, home.
    file:write(Out, <<"\e[?25l\e[2J\e[H">>),

    %% Monotonic clock for the hb-wait elapsed-seconds counter.
    T0 = erlang:monotonic_time(millisecond),
    Layout = splash_layout(),

    State0 = #{
        out         => Out,
        cols        => Cols,
        rows        => Rows,
        layout      => Layout,
        frame       => 0,
        yaw         => 0.0,
        lid         => 0.0,
        phase       => boot,
        status      => undefined,
        ip          => undefined,
        t0_ms       => T0,
        hb_wait_t0  => undefined
    },
    log_event(io_lib:format("phase=boot layout=~p", [Layout])),
    process_flag(trap_exit, true),
    try
        loop(State0)
    after
        file:write(Out, <<"\e[?25h\n">>),
        file:close(Out)
    end.

%% ============================================================
%% Main loop
%% ============================================================
%% Render + write + step_anim is wrapped in try/catch so any frame-
%% local crash (degenerate input from os:cmd, a transient EBADF on
%% /dev/console during console handover, ...) just logs and reuses
%% the previous state. The splash MUST keep moving; a frozen frame
%% on a slow boot reads as a hang.
loop(S0) ->
    S1 = poll_state(S0),
    S2 = try
             Frame = render(S1),
             file:write(maps:get(out, S1), Frame),
             step_anim(S1)
         catch
             C:R:Stk ->
                 catch log_event(io_lib:format(
                     "render-crash ~p:~p ~P",
                     [C, R, Stk, 12])),
                 S1
         end,
    timer:sleep(?SLEEP_MS),
    loop(S2).

%% ============================================================
%% State polling -- phase machine, IP discovery, HB probe
%% ============================================================
poll_state(S0 = #{phase := Phase, ip := _Ip}) ->
    S = S0#{status => read_status()},
    case Phase of
        boot ->
            case read_ip() of
                undefined -> S;
                NewIp     ->
                    log_event(io_lib:format("phase=net-up ip=~s", [NewIp])),
                    S#{phase => 'net-up', ip => NewIp}
            end;
        'net-up' ->
            case hb_ready() of
                true ->
                    log_event("phase=ready (HB ready on first poll)"),
                    S#{phase => ready};
                {false, Reason} ->
                    log_event(io_lib:format(
                        "phase=hb-wait (~s)", [Reason])),
                    HbT0 = erlang:monotonic_time(millisecond),
                    S#{phase => 'hb-wait', hb_wait_t0 => HbT0}
            end;
        'hb-wait' ->
            case hb_ready() of
                true ->
                    log_event("phase=ready (HB ready)"),
                    S#{phase => ready};
                {false, _Reason} ->
                    %% Don't spam the log -- only every ~30 polls
                    %% (~2.5 s wall) to keep splash.log readable.
                    Frame = maps:get(frame, S),
                    case Frame rem 60 of
                        0 ->
                            HbT0 = maps:get(hb_wait_t0, S),
                            Now = erlang:monotonic_time(millisecond),
                            log_event(io_lib:format(
                                "hb-wait: ~bs elapsed",
                                [(Now - HbT0) div 1000]));
                        _ -> ok
                    end,
                    S
            end;
        ready ->
            S
    end.

read_ip() ->
    case file:read_file(primary_net_path()) of
        {ok, Bin} ->
            case re:run(Bin, "(?m)^ip=([0-9.]+)",
                        [{capture, all_but_first, list}]) of
                {match, [Ip]} -> Ip;
                _             -> undefined
            end;
        _ -> undefined
    end.

read_status() ->
    case file:read_file(status_path()) of
        {ok, Bin} ->
            trim_status(binary_to_list(Bin));
        _ ->
            undefined
    end.

trim_status(Text0) ->
    Text = string:trim(Text0),
    case Text of
        "" -> undefined;
        _  -> lists:sublist(Text, 120)
    end.

%% Returns `true' when /info answered with HTTP 200, or
%% `{false, Reason}' otherwise. The Reason is a short human-readable
%% string suitable for splash.log -- not for screen.
%%
%% Speaks HTTP/1.0 over a raw gen_tcp connection rather than going
%% through inets/httpc. The probe URL contains both `~' and `@'
%% (e.g. `/~tpm@2.0a/info'); httpc URL parsing throws on that pair
%% under OTP 27. Raw gen_tcp has no URL parser to throw at all.
hb_ready() ->
    Host = probe_host(),
    Port = probe_port(),
    Path = probe_path(),
    Tmo  = ?POLL_TIMEOUT_MS,
    %% `{packet, line}' makes recv block until a CRLF-terminated line
    %% lands -- exactly the HTTP status line. Raw mode would let
    %% recv return after the first TCP segment, which can split
    %% "HTTP/1." and "1 200 OK\r\n..." under a busy cowboy and miss
    %% the 200 prefix.
    case gen_tcp:connect(Host, Port,
                         [binary, {active, false},
                          {packet, line}, {nodelay, true}],
                         Tmo) of
        {ok, Sock} ->
            try
                Req = io_lib:format(
                        "GET ~s HTTP/1.0\r\nHost: ~s:~b\r\n"
                        "Connection: close\r\n\r\n",
                        [Path, Host, Port]),
                case gen_tcp:send(Sock, Req) of
                    ok ->
                        case gen_tcp:recv(Sock, 0, Tmo) of
                            {ok, <<"HTTP/1.", _, " 200", _/binary>>} ->
                                true;
                            {ok, <<"HTTP/1.", _, " ", C1, C2, C3,
                                   _/binary>>} ->
                                {false, io_lib:format(
                                          "HTTP ~c~c~c", [C1,C2,C3])};
                            {ok, Other} ->
                                {false, io_lib:format(
                                          "unparsed ~P",
                                          [Other, 8])};
                            {error, Reason} ->
                                {false, io_lib:format(
                                          "recv ~p", [Reason])}
                        end;
                    {error, Reason} ->
                        {false, io_lib:format("send ~p", [Reason])}
                end
            after
                gen_tcp:close(Sock)
            end;
        {error, Reason} ->
            {false, io_lib:format("conn ~p", [Reason])}
    end.

%% ============================================================
%% Animation state advance
%% ============================================================
%% The yaw advances every frame regardless of phase -- the spin
%% never locks. The lid eases toward the open target with the
%% per-frame step defined by ?LID_EASE; a smaller value is a slower,
%% more deliberate open (asymptotic, so it never quite stops moving
%% but is visually fully-open after ~7 s at 12 fps with 0.04).
step_anim(S = #{frame := F, yaw := Y, lid := L}) ->
    F1 = F + 1,
    Y1 = Y + ?YAW_PER_FRAME,
    L1 = L + (?LID_TARGET - L) * ?LID_EASE,
    S#{frame => F1, yaw => Y1, lid => L1}.

%% ============================================================
%% 3D model + projection
%% ============================================================
%% Laptop in laptop-width units. +x right, +y up, +z forward.
%% Origin at hinge midpoint (back-top edge of base).
%% Base: 4.0 wide, 3.0 deep, 0.22 tall. Hinge at z=-1.5, y=0.
%% Lid:  4.0 wide, 2.5 tall. Rotates around the hinge edge.
%% lid_angle: 0 = closed flat on base; pi/2 = upright.
laptop_edges(LidAngle) ->
    Base = base_edges(),
    Lid  = lid_edges(LidAngle),
    Base ++ Lid.

base_edges() ->
    %% Just the 4 top edges of the base + the 4 bottom edges +
    %% the 4 vertical corner edges -- a 12-edge wireframe gets too
    %% busy at our resolution. Drop to 6: top rectangle + the two
    %% front-facing corners only, which reads as "thin slab" cleanly.
    Pt = [{-2.0, 0.00, -1.5}, {2.0, 0.00, -1.5},   %% back-top
          {-2.0, 0.00,  1.5}, {2.0, 0.00,  1.5}],  %% front-top
    Pb = [{-2.0,-0.22,  1.5}, {2.0,-0.22,  1.5}],  %% front-bottom
    %% Top rectangle (4 edges).
    Top = [{nth(1, Pt), nth(2, Pt)},
           {nth(3, Pt), nth(4, Pt)},
           {nth(1, Pt), nth(3, Pt)},
           {nth(2, Pt), nth(4, Pt)}],
    %% Front-bottom rectangle hint: front-top to front-bottom on
    %% each side, plus the front-bottom edge.
    Front = [{nth(3, Pt), nth(1, Pb)},
             {nth(4, Pt), nth(2, Pb)},
             {nth(1, Pb), nth(2, Pb)}],
    Top ++ Front.

lid_edges(A) ->
    %% Lid corners in local lid coords. Hinge is at origin (back-top
    %% edge of base). Closed lid sits FLAT ON TOP of the base, so the
    %% top edge starts at z=+LH (forward), y=0. Opening rotates the
    %% top edge UP and back toward the hinge.
    %%   A=0      -> closed flat (top at +z)
    %%   A=pi/2   -> upright open (top at +y)
    %%   A=1.85   -> ~106 deg, classic working angle (slight back-tilt)
    LH = 2.5,
    Local = [{-2.0, 0.0, 0.0},   %% 1: bottom-left at hinge
             { 2.0, 0.0, 0.0},   %% 2: bottom-right at hinge
             {-2.0, 0.0,  LH},   %% 3: top-left, lid closed
             { 2.0, 0.0,  LH}],  %% 4: top-right, lid closed
    Rot = [rotate_lid(P, A) || P <- Local],
    %% Translate so the hinge sits at z=-1.5, y=0 in world.
    World = [{X, Y, Z + (-1.5)} || {X, Y, Z} <- Rot],
    Idx = [{1,2},{3,4},{1,3},{2,4}],
    [{nth(I, World), nth(J, World)} || {I, J} <- Idx].

%% Rotation that takes the closed lid (top at +z) up to open (top at
%% +y) as A goes from 0 -> pi/2.
rotate_lid({X, Y, Z}, A) ->
    Ca = math:cos(A), Sa = math:sin(A),
    {X, Y * Ca + Z * Sa, -Y * Sa + Z * Ca}.

rotate_y({X, Y, Z}, A) ->
    Ca = math:cos(A), Sa = math:sin(A),
    {X * Ca + Z * Sa, Y, -X * Sa + Z * Ca}.

%% Project a 3D point to a 2D grid cell.
%% Orthographic projection with a Y-axis tilt for the 3/4 view.
project_at({X, Y, Z}, Xc, Yc, Scale) ->
    Tilt = 0.45,                                  %% radians, look-down
    Yt = Y * math:cos(Tilt) - Z * math:sin(Tilt),
    %% Char cells are roughly 2:1 tall:wide; scale Y by half.
    Cx = Xc + X * Scale,
    Cy = Yc - Yt * Scale * 0.5,
    {round(Cx), round(Cy)}.

%% ============================================================
%% Bresenham line draw onto the grid
%% ============================================================
%% Grid is map: {Row, Col} => char.
draw_line(Grid, W, H, P1, P2) ->
    {X1, Y1} = P1, {X2, Y2} = P2,
    Ch = pick_char(X1, Y1, X2, Y2),
    bres(Grid, W, H, X1, Y1, X2, Y2, Ch).

pick_char(X1, Y1, X2, Y2) ->
    Dx = abs(X2 - X1), Dy = abs(Y2 - Y1),
    if
        Dy * 2 < Dx -> $-;
        Dx * 2 < Dy -> $|;
        (X2 - X1) * (Y2 - Y1) > 0 -> $\\;
        true -> $/
    end.

bres(Grid, W, H, X0, Y0, X1, Y1, Ch) ->
    Dx = abs(X1 - X0), Sx = if X0 < X1 -> 1; true -> -1 end,
    Dy = -abs(Y1 - Y0), Sy = if Y0 < Y1 -> 1; true -> -1 end,
    Err = Dx + Dy,
    bres_step(Grid, W, H, X0, Y0, X1, Y1, Dx, Dy, Sx, Sy, Err, Ch).

bres_step(Grid, W, H, X, Y, X1, Y1, _, _, _, _, _, _) when X =:= X1, Y =:= Y1 ->
    plot(Grid, W, H, X, Y, $+);
bres_step(Grid, W, H, X, Y, X1, Y1, Dx, Dy, Sx, Sy, Err, Ch) ->
    G1 = plot(Grid, W, H, X, Y, Ch),
    E2 = 2 * Err,
    {X2, Err1a} =
        if E2 >= Dy -> {X + Sx, Err + Dy};
           true     -> {X, Err}
        end,
    {Y2, Err1} =
        if E2 =< Dx -> {Y + Sy, Err1a + Dx};
           true     -> {Y, Err1a}
        end,
    bres_step(G1, W, H, X2, Y2, X1, Y1, Dx, Dy, Sx, Sy, Err1, Ch).

plot(Grid, W, H, X, Y, Ch) ->
    case X >= 1 andalso X =< W andalso Y >= 1 andalso Y =< H of
        true  -> Grid#{{Y, X} => cell(Ch)};
        false -> Grid
    end.

cell(Ch) when is_integer(Ch), Ch >= 0, Ch =< 255 ->
    Ch;
cell(Ch) when is_integer(Ch) ->
    unicode:characters_to_binary([Ch]);
cell(Ch) ->
    Ch.

%% ============================================================
%% Frame composition + ANSI emission
%% ============================================================
render(#{cols := W, rows := H, layout := Layout, frame := Frame,
         yaw := Yaw, lid := Lid, phase := Phase, status := Status, ip := Ip,
         hb_wait_t0 := HbT0}) ->
    Footer = footer_text(Phase, Ip, HbT0, Status),
    Grid = case Layout of
        provision -> render_provision_grid(W, H, Yaw, Lid, Footer);
        _         -> render_blue_grid(W, H, Yaw, Lid, Footer, Ip)
    end,
    %% Emit: cursor home, theme colour, then row by row separated
    %% by CRLF. Every row is full-width, so old frame cells are
    %% overwritten without needing a full clear at 12 fps.
    Rows = [emit_row(Grid, W, R) || R <- lists:seq(1, H)],
    [<<"\e[H">>, theme_prefix(Layout, Phase, Frame),
     lists:join(<<"\r\n">>, Rows), <<"\e[0m">>].

render_blue_grid(W, H, Yaw, Lid, Footer, Ip) ->
    Grid0 = #{},
    LeftW = max(70, min(80, W div 2)),
    Gap = 3,
    RightX = LeftW + Gap,
    RightW = max(34, W - RightX - 2),
    Url = node_url(Ip),
    Scale = max(8.0, min(RightW / 4.05, (H - 4) / 1.9)),
    Grid1 = draw_laptop(Grid0, W, H, Yaw, Lid,
                        RightX + RightW * 0.58 - 5, H * 0.69, Scale),
    Grid2 = overlay_lines(Grid1, W, H, 6, 3, blue_left_top_lines(LeftW)),
    draw_blue_qr_panel(Grid2, W, H, 6, 17, LeftW - 4, Url, Footer, Ip).

render_provision_grid(W, H, Yaw, Lid, Footer) ->
    Grid0 = #{},
    LeftW = max(48, min(72, W div 2)),
    Gap = 3,
    RightX = LeftW + Gap,
    RightW = max(34, W - RightX - 2),
    Scale = max(8.0, min(RightW / 4.05, (H - 4) / 1.9)),
    Grid1 = draw_laptop(Grid0, W, H, Yaw, Lid,
                        RightX + RightW * 0.58 - 5, H * 0.69, Scale),
    Grid2 = overlay_lines(Grid1, W, H, 6, 3,
                          blue_left_top_lines(LeftW)),
    draw_provision_panel(Grid2, W, H, 6, 16, LeftW - 4, Footer).

draw_provision_panel(Grid, W, H, X, Y, ColW, Footer) ->
    PanelW = (min(64, max(36, ColW)) div 2) * 2,
    PanelH = max(12, min(H - Y - 2, 30)),
    TextX = X + 3,
    TextW = PanelW - 6,
    Grid1 = draw_tile_box(fill_rect(Grid, W, H, X + 2, Y + 1,
                                    PanelW - 4, PanelH - 2),
                          W, H, X, Y, PanelW div 2, PanelH),
    case provision_mode() of
        report ->
            draw_provision_report(Grid1, W, H, TextX, Y + 2,
                                  TextW, PanelH - 4);
        prompt ->
            draw_provision_prompt(Grid1, W, H, TextX, Y + 2,
                                  TextW, PanelH - 4);
        warning ->
            draw_provision_warning(Grid1, W, H, TextX, Y, TextW,
                                   PanelH, Footer)
    end.

draw_provision_warning(Grid, W, H, TextX, Y, TextW, PanelH, Footer) ->
    WarningLines = provision_warning_lines(TextW, PanelH - 9),
    Grid1 = overlay_centered_lines(Grid, W, H, TextX, Y + 2,
                                   TextW, WarningLines),
    Prompt = "Type I UNDERSTAND. to continue:",
    Input = "> " ++ read_provision_input() ++ "_",
    PromptY = Y + PanelH - 5,
    InputY = Y + PanelH - 3,
    Grid2 = overlay_text(Grid1, W, H, TextX, PromptY, Prompt),
    Grid3 = overlay_text(Grid2, W, H, TextX, InputY, fit_text(Input, TextW)),
    case provision_footer_visible(Footer) of
        false -> Grid3;
        true  -> overlay_text(Grid3, W, H, TextX, Y + PanelH - 2,
                              fit_text(Footer, TextW))
    end.

draw_provision_report(Grid, W, H, TextX, Y, TextW, MaxLines) ->
    Header = "!!! POST-PROVISIONING REPORT !!!",
    Grid1 = overlay_centered_lines(Grid, W, H, TextX, Y, TextW, [Header]),
    Lines = provision_report_lines(TextW, max(1, MaxLines - 2)),
    overlay_lines(Grid1, W, H, TextX, Y + 2, Lines).

draw_provision_prompt(Grid, W, H, TextX, Y, TextW, MaxLines) ->
    Header = "!!! NON-VOLATILE STORAGE !!!",
    Grid1 = overlay_centered_lines(Grid, W, H, TextX, Y, TextW, [Header]),
    Lines = provision_report_lines(TextW, max(1, MaxLines - 5)),
    Grid2 = overlay_lines(Grid1, W, H, TextX, Y + 2, Lines),
    PromptY = Y + MaxLines - 2,
    InputY = Y + MaxLines,
    Grid3 = overlay_text(Grid2, W, H, TextX, PromptY,
                         fit_text(read_provision_prompt(), TextW)),
    Input = "> " ++ read_provision_input() ++ "_",
    overlay_text(Grid3, W, H, TextX, InputY, fit_text(Input, TextW)).

provision_footer_visible("Type I UNDERSTAND. to continue.") ->
    false;
provision_footer_visible("Type I UNDERSTAND. to continue:") ->
    false;
provision_footer_visible(_) ->
    true.

provision_warning_lines(Width, MaxLines) ->
    Paragraphs = [
        "!!! CAUTION: SECURE BOOT KEY PROVISIONER",
        "Performing this operation is irreversible and will render your machine unable to boot other operating systems.",
        "There is a very real possibility that it will cause harm to the viability of the attached hardware.",
        "Nobody will help you, and nobody can save your machine.",
        "You have been warned."
    ],
    Lines0 = provision_spaced_lines(Paragraphs, Width),
    lists:sublist(Lines0, MaxLines).

provision_mode() ->
    case file:read_file(provision_mode_path()) of
        {ok, Bin} ->
            case string:trim(binary_to_list(Bin)) of
                "report" -> report;
                "prompt" -> prompt;
                _ -> warning
            end;
        _ ->
            warning
    end.

provision_report_lines(Width, MaxLines) ->
    Lines0 =
        case file:read_file(provision_report_path()) of
            {ok, Bin} ->
                provision_report_lines_from_bin(Bin, Width);
            _ ->
                ["Provisioning report is pending."]
        end,
    lists:sublist(Lines0, MaxLines).

provision_report_lines_from_bin(Bin, Width) ->
    Lines =
        string:split(binary_to_list(Bin), "\n", all),
    Wrapped =
        lists:flatmap(
          fun(Line) ->
              case wrap_words(string:tokens(string:trim(Line), " \t\r\n"),
                              Width) of
                  [] -> [""];
                  Ls -> Ls
              end
          end,
          Lines),
    case Wrapped of
        [] -> ["Provisioning report is pending."];
        _ -> Wrapped
    end.

provision_spaced_lines([], _Width) ->
    [];
provision_spaced_lines([P], Width) ->
    wrap_words(string:tokens(P, " \t\r\n"), Width);
provision_spaced_lines([P | Rest], Width) ->
    wrap_words(string:tokens(P, " \t\r\n"), Width) ++
        [""] ++ provision_spaced_lines(Rest, Width).

read_provision_input() ->
    case file:read_file(provision_input_path()) of
        {ok, Bin} ->
            fit_text(binary_to_list(Bin), 80);
        _ ->
            ""
    end.

read_provision_prompt() ->
    case file:read_file(provision_prompt_path()) of
        {ok, Bin} ->
            case string:trim(binary_to_list(Bin)) of
                "" -> "Type `SKIP` or `DESTROY N[ -> ID]`.";
                Text -> Text
            end;
        _ ->
            "Type `SKIP` or `DESTROY N[ -> ID]`."
    end.

blue_left_top_lines(LeftW) ->
    Max = max(12, LeftW - 3),
    [fit_text(Line, Max) || Line <- hyperbeam_greeter_lines()].

hyperbeam_greeter_lines() ->
    %% Mirrors hb_http_server:print_greeter/2 without the operator,
    %% config, border, and version rows that do not belong on splash.
    ["██╗  ██╗██╗   ██╗██████╗ ███████╗██████╗",
     "██║  ██║╚██╗ ██╔╝██╔══██╗██╔════╝██╔══██╗",
     "███████║ ╚████╔╝ ██████╔╝█████╗  ██████╔╝",
     "██╔══██║  ╚██╔╝  ██╔═══╝ ██╔══╝  ██╔══██╗",
     "██║  ██║   ██║   ██║     ███████╗██║  ██║",
     "╚═╝  ╚═╝   ╚═╝   ╚═╝     ╚══════╝╚═╝  ╚═╝",
     "██████╗ ███████╗ █████╗ ███╗   ███╗",
     "██╔══██╗██╔════╝██╔══██╗████╗ ████║",
     "██████╔╝█████╗  ███████║██╔████╔██║",
     "██╔══██╗██╔══╝  ██╔══██║██║╚██╔╝██║ EAT GLASS,",
     "██████╔╝███████╗██║  ██║██║ ╚═╝ ██║ BUILD THE",
     "╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝ FUTURE."].

node_url(undefined) ->
    "http://<node>:8734/";
node_url(Ip) ->
    "http://" ++ Ip ++ ":8734/".

fit_text(Text, Max) when length(Text) =< Max ->
    Text;
fit_text(_Text, Max) when Max =< 1 ->
    "";
fit_text(Text, Max) ->
    lists:sublist(Text, Max - 1) ++ "~".

draw_blue_qr_panel(Grid, W, H, X, Y, _ColW, Url, Footer, Ip) ->
    Rows = qr_display_rows_for_url(Url),
    QrMods = length(hd(Rows)),
    QrW = QrMods * 2,
    QrH = length(Rows),
    QrX = X,
    Grid1 = fill_rect(Grid, W, H, QrX, Y, QrW, QrH),
    case {status_word(Footer), Ip} of
        {"READY", _} when Ip =/= undefined ->
            draw_qr_double_rows(Grid1, W, H, QrX, Y, Rows);
        _ ->
            draw_qr_placeholder(Grid1, W, H, QrX, Y, QrMods, QrH, Footer)
    end.

qr_display_rows_for_url(Url) ->
    qr_crop_quiet_zone(qr_rows_for_url(Url), 4).

qr_crop_quiet_zone(Rows, Quiet) ->
    InnerH = length(Rows) - Quiet * 2,
    InnerRows = lists:sublist(lists:nthtail(Quiet, Rows), InnerH),
    [lists:sublist(lists:nthtail(Quiet, Row), length(Row) - Quiet * 2) ||
        Row <- InnerRows].

qr_rows_for_url(Url) ->
    Bin = unicode:characters_to_binary(Url),
    case byte_size(Bin) =< 32 of
        true  -> qr_v2_l_rows(Bin);
        false -> qr_v2_l_rows(<<"http://node-too-long/">>)
    end.

qr_v2_l_rows(Data) ->
    Size = 25,
    DataCodewords = qr_data_codewords(Data, 34),
    EccCodewords = rs_remainder(DataCodewords, 10),
    Bits = lists:append([bits_int(Cw, 8) || Cw <- DataCodewords ++ EccCodewords]),
    {Base, Reserved} = qr_base_v2(Size),
    WithData = qr_place_bits(Base, Reserved, Size, Bits),
    WithFormat = qr_apply_format_l_mask0(WithData, Size),
    qr_add_quiet_zone(WithFormat, Size, 4).

qr_data_codewords(Data, Target) ->
    Bits0 = [0, 1, 0, 0] ++ bits_int(byte_size(Data), 8) ++ binary_bits(Data),
    MaxBits = Target * 8,
    Terminator = lists:duplicate(max(0, min(4, MaxBits - length(Bits0))), 0),
    Bits1 = pad_bits_to_byte(Bits0 ++ Terminator),
    pad_codewords(bits_to_codewords(Bits1), Target, 16#EC).

binary_bits(Bin) ->
    lists:append([bits_int(Byte, 8) || <<Byte:8>> <= Bin]).

bits_int(N, Width) ->
    [(N bsr Shift) band 1 || Shift <- lists:seq(Width - 1, 0, -1)].

pad_bits_to_byte(Bits) ->
    case length(Bits) rem 8 of
        0 -> Bits;
        Rem -> Bits ++ lists:duplicate(8 - Rem, 0)
    end.

bits_to_codewords([]) ->
    [];
bits_to_codewords(Bits) ->
    {ByteBits, Rest} = lists:split(8, Bits),
    [bits_to_int(ByteBits) | bits_to_codewords(Rest)].

bits_to_int(Bits) ->
    lists:foldl(fun(Bit, Acc) -> (Acc bsl 1) bor Bit end, 0, Bits).

pad_codewords(Codewords, Target, _Next) when length(Codewords) >= Target ->
    lists:sublist(Codewords, Target);
pad_codewords(Codewords, Target, Next) ->
    Following = case Next of
        16#EC -> 16#11;
        _     -> 16#EC
    end,
    pad_codewords(Codewords ++ [Next], Target, Following).

rs_remainder(Data, EccLen) ->
    Generator = rs_generator(EccLen),
    GenTail = tl(Generator),
    Rem0 = lists:duplicate(EccLen, 0),
    lists:foldl(
      fun(Byte, Rem) ->
          Factor = Byte bxor hd(Rem),
          Shifted = tl(Rem) ++ [0],
          [R bxor gf_mul(Factor, G) || {R, G} <- lists:zip(Shifted, GenTail)]
      end,
      Rem0,
      Data).

rs_generator(Degree) ->
    lists:foldl(
      fun(I, Poly) ->
          poly_mul_high(Poly, [1, gf_pow2(I)])
      end,
      [1],
      lists:seq(0, Degree - 1)).

poly_mul_high(P, Q) ->
    PLen = length(P),
    QLen = length(Q),
    [poly_mul_coeff(P, Q, PLen, QLen, K) ||
        K <- lists:seq(0, PLen + QLen - 2)].

poly_mul_coeff(P, Q, PLen, QLen, K) ->
    lists:foldl(
      fun(I, Acc) ->
          J = K - I,
          case I >= 0 andalso I < PLen andalso J >= 0 andalso J < QLen of
              true ->
                  Acc bxor gf_mul(nth0(I, P), nth0(J, Q));
              false ->
                  Acc
          end
      end,
      0,
      lists:seq(0, K)).

nth0(I, List) ->
    lists:nth(I + 1, List).

gf_pow2(0) ->
    1;
gf_pow2(N) ->
    lists:foldl(fun(_, Acc) -> gf_mul(Acc, 2) end, 1, lists:seq(1, N)).

gf_mul(A, B) ->
    gf_mul(A, B, 0).

gf_mul(_A, 0, Acc) ->
    Acc;
gf_mul(A, B, Acc) ->
    Acc1 = case B band 1 of
        1 -> Acc bxor A;
        _ -> Acc
    end,
    A0 = A bsl 1,
    A1 = case A0 band 16#100 of
        0 -> A0 band 16#FF;
        _ -> (A0 bxor 16#11D) band 16#FF
    end,
    gf_mul(A1, B bsr 1, Acc1).

qr_base_v2(Size) ->
    S0 = {#{}, #{}},
    S1 = qr_draw_finder(S0, Size, 0, 0),
    S2 = qr_draw_finder(S1, Size, 0, Size - 7),
    S3 = qr_draw_finder(S2, Size, Size - 7, 0),
    S4 = qr_draw_alignment(S3, Size, 18, 18),
    S5 = qr_draw_timing(S4, Size),
    S6 = qr_put(S5, Size, 4 * 2 + 9, 8, true, true),
    qr_reserve_format(S6, Size).

qr_draw_finder(State, Size, R0, C0) ->
    lists:foldl(
      fun(R, SRow) ->
          lists:foldl(
            fun(C, S) ->
                Row = R0 + R,
                Col = C0 + C,
                Separator = R =:= -1 orelse R =:= 7 orelse
                            C =:= -1 orelse C =:= 7,
                Dark = (not Separator) andalso
                       (R =:= 0 orelse R =:= 6 orelse
                        C =:= 0 orelse C =:= 6 orelse
                        (R >= 2 andalso R =< 4 andalso
                         C >= 2 andalso C =< 4)),
                qr_put(S, Size, Row, Col, Dark, true)
            end,
            SRow,
            lists:seq(-1, 7))
      end,
      State,
      lists:seq(-1, 7)).

qr_draw_alignment(State, Size, R0, C0) ->
    lists:foldl(
      fun(R, SRow) ->
          lists:foldl(
            fun(C, S) ->
                Dark = abs(R) =:= 2 orelse abs(C) =:= 2 orelse
                       (R =:= 0 andalso C =:= 0),
                qr_put(S, Size, R0 + R, C0 + C, Dark, true)
            end,
            SRow,
            lists:seq(-2, 2))
      end,
      State,
      lists:seq(-2, 2)).

qr_draw_timing(State, Size) ->
    lists:foldl(
      fun(I, S0) ->
          Dark = I rem 2 =:= 0,
          S1 = qr_put(S0, Size, 6, I, Dark, true),
          qr_put(S1, Size, I, 6, Dark, true)
      end,
      State,
      lists:seq(8, Size - 9)).

qr_reserve_format(State, Size) ->
    lists:foldl(
      fun({R, C}, S) -> qr_put(S, Size, R, C, false, true) end,
      State,
      qr_format_coords(Size)).

qr_put({Modules, Reserved}, Size, Row, Col, Dark, Reserve) ->
    case Row >= 0 andalso Row < Size andalso Col >= 0 andalso Col < Size of
        true ->
            R1 = case Reserve of
                true  -> Reserved#{{Row, Col} => true};
                false -> Reserved
            end,
            {Modules#{{Row, Col} => Dark}, R1};
        false ->
            {Modules, Reserved}
    end.

qr_place_bits(Modules0, Reserved, Size, Bits0) ->
    Positions = qr_data_positions(Size, Reserved),
    {Modules, _Bits} = lists:foldl(
      fun({Row, Col}, {M, Bits}) ->
          {Bit, Rest} = case Bits of
              [B | Bs] -> {B, Bs};
              []       -> {0, []}
          end,
          Mask = (Row + Col) rem 2 =:= 0,
          Dark = (Bit =:= 1) =/= Mask,
          {M#{{Row, Col} => Dark}, Rest}
      end,
      {Modules0, Bits0},
      Positions),
    Modules.

qr_data_positions(Size, Reserved) ->
    {Positions, _Dir} = lists:foldl(
      fun(Col, {Acc, Dir}) ->
          Rows = case Dir of
              up   -> lists:seq(Size - 1, 0, -1);
              down -> lists:seq(0, Size - 1)
          end,
          Pair = [{R, C} || R <- Rows,
                            C <- [Col, Col - 1],
                            not maps:is_key({R, C}, Reserved)],
          {Acc ++ Pair, flip_dir(Dir)}
      end,
      {[], up},
      qr_column_starts(Size - 1)),
    Positions.

qr_column_starts(Col) when Col =< 0 ->
    [];
qr_column_starts(6) ->
    qr_column_starts(5);
qr_column_starts(Col) ->
    [Col | qr_column_starts(Col - 2)].

flip_dir(up) -> down;
flip_dir(down) -> up.

qr_apply_format_l_mask0(Modules, Size) ->
    Bits = [(16#77C4 bsr I) band 1 || I <- lists:seq(0, 14)],
    lists:foldl(
      fun({Bit, Coord}, M) ->
          M#{Coord => Bit =:= 1}
      end,
      Modules,
      lists:zip(Bits ++ Bits, qr_format_coords(Size))).

qr_format_coords(Size) ->
    [{0, 8}, {1, 8}, {2, 8}, {3, 8}, {4, 8}, {5, 8}, {7, 8},
     {8, 8}, {8, 7}, {8, 5}, {8, 4}, {8, 3}, {8, 2}, {8, 1},
     {8, 0},
     {8, Size - 1}, {8, Size - 2}, {8, Size - 3}, {8, Size - 4},
     {8, Size - 5}, {8, Size - 6}, {8, Size - 7}, {8, Size - 8},
     {Size - 7, 8}, {Size - 6, 8}, {Size - 5, 8}, {Size - 4, 8},
     {Size - 3, 8}, {Size - 2, 8}, {Size - 1, 8}].

qr_add_quiet_zone(Modules, Size, Quiet) ->
    Total = Size + Quiet * 2,
    [[qr_quiet_module(Modules, Size, Quiet, R, C) ||
        C <- lists:seq(0, Total - 1)] ||
        R <- lists:seq(0, Total - 1)].

qr_quiet_module(Modules, Size, Quiet, R, C) ->
    InnerR = R - Quiet,
    InnerC = C - Quiet,
    case InnerR >= 0 andalso InnerR < Size andalso
         InnerC >= 0 andalso InnerC < Size of
        true  -> maps:get({InnerR, InnerC}, Modules, false);
        false -> false
    end.

draw_qr_double_rows(Grid, W, H, X, Y, Rows) ->
    lists:foldl(
      fun({R, Row}, G0) ->
          lists:foldl(
            fun({C, true}, G) ->
                    draw_qr_tile(G, W, H, X + C * 2, Y + R);
               ({_C, false}, G) ->
                    G
            end,
            G0,
            lists:zip(lists:seq(0, length(Row) - 1), Row))
      end,
      Grid,
      lists:zip(lists:seq(0, length(Rows) - 1), Rows)).

draw_qr_placeholder(Grid, W, H, X, Y, ModsW, ModsH, Footer) ->
    G1 = lists:foldl(
      fun(R, G0) ->
          lists:foldl(
            fun(C, G) ->
                case R =:= 0 orelse R =:= ModsH - 1 orelse
                     C =:= 0 orelse C =:= ModsW - 1 of
                    true  -> draw_qr_tile(G, W, H, X + C * 2, Y + R);
                    false -> G
                end
            end,
            G0,
            lists:seq(0, ModsW - 1))
      end,
      Grid,
      lists:seq(0, ModsH - 1)),
    TextW = max(8, ModsW * 2 - 8),
    MaxLines = max(1, min(5, ModsH - 4)),
    Lines = wrap_status_lines(Footer, TextW, MaxLines),
    StartY = Y + max(2, (ModsH - length(Lines)) div 2),
    lists:foldl(
      fun({I, Line}, G) ->
          TextX = X + max(2, (ModsW * 2 - length(Line)) div 2),
          overlay_text(G, W, H, TextX, StartY + I, Line)
      end,
      G1,
      lists:zip(lists:seq(0, length(Lines) - 1), Lines)).

draw_tile_box(Grid, W, H, X, Y, ModsW, ModsH) ->
    lists:foldl(
      fun(R, G0) ->
          lists:foldl(
            fun(C, G) ->
                case R =:= 0 orelse R =:= ModsH - 1 orelse
                     C =:= 0 orelse C =:= ModsW - 1 of
                    true  -> draw_qr_tile(G, W, H, X + C * 2, Y + R);
                    false -> G
                end
            end,
            G0,
            lists:seq(0, ModsW - 1))
      end,
      Grid,
      lists:seq(0, ModsH - 1)).

wrap_status_lines(Text0, Width, MaxLines) ->
    Words = string:tokens(string:trim(Text0), " \t\r\n"),
    Lines0 = case wrap_words(Words, Width) of
        [] -> [""];
        Wrapped -> Wrapped
    end,
    case length(Lines0) =< MaxLines of
        true ->
            Lines0;
        false ->
            Head = lists:sublist(Lines0, MaxLines - 1),
            Tail = string:join(lists:nthtail(MaxLines - 1, Lines0), " "),
            Head ++ [fit_text(Tail, Width)]
    end.

wrap_words(Words, Width) ->
    {LinesRev, Current} =
        lists:foldl(
          fun(Word, {Acc, Cur}) ->
              add_wrapped_word(Word, Width, Acc, Cur)
          end,
          {[], ""},
          Words),
    lists:reverse(case Current of
        "" -> LinesRev;
        _  -> [Current | LinesRev]
    end).

add_wrapped_word(Word, Width, Acc, Cur) when length(Word) > Width ->
    Acc1 = case Cur of
        "" -> Acc;
        _  -> [Cur | Acc]
    end,
    {lists:reverse(split_long_word(Word, Width)) ++ Acc1, ""};
add_wrapped_word(Word, Width, Acc, "") ->
    {Acc, fit_text(Word, Width)};
add_wrapped_word(Word, Width, Acc, Cur) ->
    Candidate = Cur ++ " " ++ Word,
    case length(Candidate) =< Width of
        true  -> {Acc, Candidate};
        false -> {[Cur | Acc], fit_text(Word, Width)}
    end.

split_long_word("", _Width) ->
    [];
split_long_word(Word, Width) when length(Word) =< Width ->
    [Word];
split_long_word(Word, Width) ->
    Take = max(1, Width - 1),
    Head = lists:sublist(Word, Take) ++ "~",
    Rest = lists:nthtail(Take, Word),
    [Head | split_long_word(Rest, Width)].

draw_qr_tile(Grid, W, H, X, Y) ->
    Block = <<226, 150, 136>>,
    plot(plot(Grid, W, H, X, Y, Block), W, H, X + 1, Y, Block).

theme_prefix(blue, ready, _)    -> blue_theme_prefix();
theme_prefix(blue, _, _)        -> blue_theme_prefix();
theme_prefix(provision, _, _)   -> provision_theme_prefix();
theme_prefix(_, ready, _)       -> blue_theme_prefix();
theme_prefix(_, _, _)           -> blue_theme_prefix().

blue_theme_prefix() ->
    %% Linux fbcon supports a 16-colour palette, not true per-cell RGB.
    %% Remap slot 4 (blue background) to a dark indigo/purple and slot
    %% 15 (bright white foreground) to a clean white, then draw every
    %% full-width row as bright white text on that blue block colour.
    <<"\e]P415123a\e]Pff8fbff\e[1;37;44m">>.

provision_theme_prefix() ->
    %% Remap ANSI red to a deep warning red and draw white-on-red full
    %% rows. The provisioner is intentionally visually distinct from
    %% the production blue proof splash.
    <<"\e]P1400000\e]Pff8fbff\e[1;37;41m">>.

draw_laptop(Grid0, W, H, Yaw, Lid, Xc, Yc, Scale) ->
    Edges = laptop_edges(Lid),
    Edges1 = [{rotate_y(P, Yaw), rotate_y(Q, Yaw)} || {P, Q} <- Edges],
    Edges2 = [{project_at(P, Xc, Yc, Scale),
               project_at(Q, Xc, Yc, Scale)}
              || {P, Q} <- Edges1],
    lists:foldl(fun({P1, P2}, G) -> draw_line(G, W, H, P1, P2) end,
                Grid0, Edges2).

emit_row(Grid, W, Row) ->
    [maps:get({Row, Col}, Grid, $\s) || Col <- lists:seq(1, W)].

overlay_text(Grid, W, H, X, Y, Text) ->
    case Y >= 1 andalso Y =< H of
        true ->
            lists:foldl(
              fun({I, Ch}, G) ->
                  plot(G, W, H, X + I, Y, Ch)
              end,
              Grid,
              lists:zip(lists:seq(0, length(Text) - 1), Text));
        false ->
            Grid
    end.

overlay_lines(Grid, W, H, X, Y, Lines) ->
    lists:foldl(
      fun({I, Line}, G) -> overlay_text(G, W, H, X, Y + I, Line) end,
      Grid,
      lists:zip(lists:seq(0, length(Lines) - 1), Lines)).

overlay_centered_lines(Grid, W, H, X, Y, Width, Lines) ->
    lists:foldl(
      fun({I, Line}, G) ->
          Pad = max(0, (Width - length(Line)) div 2),
          overlay_text(G, W, H, X + Pad, Y + I, Line)
      end,
      Grid,
      lists:zip(lists:seq(0, length(Lines) - 1), Lines)).

fill_rect(Grid, W, H, X, Y, BW, BH) when BW > 0, BH > 0 ->
    lists:foldl(
      fun(R, G0) ->
          lists:foldl(
            fun(C, G) -> plot(G, W, H, C, R, $\s) end,
            G0,
            lists:seq(X, X + BW - 1))
      end,
      Grid,
      lists:seq(Y, Y + BH - 1));
fill_rect(Grid, _, _, _, _, _, _) ->
    Grid.

status_word(Text) ->
    case Text of
        "Running" ++ _ -> "READY";
        "Starting HyperBEAM" ++ _ -> "HB STARTING";
        "Network" ++ _ -> "NETWORK UP";
        "Connecting to Wi-Fi" ++ _ -> "WIFI";
        "Authenticating Wi-Fi" ++ _ -> "WIFI";
        "Waiting for Wi-Fi" ++ _ -> "WIFI";
        "Waiting for a network" ++ _ -> "NETWORK";
        "Requesting a network" ++ _ -> "DHCP";
        "Boot stopped" ++ _ -> "STOPPED";
        _ -> "BOOTING"
    end.

%% Status line texts -- the only words the operator sees on screen
%% during boot. Before networking is up, init writes the current
%% high-level stage into a tmpfs file; after DHCP, the splash owns the
%% network/HB-ready phase machine itself.
footer_text(boot, _, _, Status) ->
    default_status(Status, "Starting LapEE.");
footer_text('net-up', undefined, _, _) ->
    "Network is up; starting HyperBEAM.";
footer_text('net-up', Ip, _, _) ->
    "Network is up (" ++ Ip ++ "); starting HyperBEAM.";
footer_text('hb-wait', undefined, _, _) ->
    "Starting HyperBEAM.";
footer_text('hb-wait', Ip, undefined, _) ->
    "Starting HyperBEAM. " ++ Ip;
footer_text('hb-wait', Ip, HbT0, _) ->
    Now = erlang:monotonic_time(millisecond),
    Secs = (Now - HbT0) div 1000,
    "Starting HyperBEAM. " ++ Ip ++
        " (" ++ integer_to_list(Secs) ++ "s)";
footer_text(ready, undefined, _, _) ->
    "Running.";
footer_text(ready, Ip, _, _) ->
    "Running at http://" ++ Ip ++ ":8734/";
footer_text(_, _, _, Status) ->
    default_status(Status, "").

default_status(undefined, Fallback) -> Fallback;
default_status("", Fallback)        -> Fallback;
default_status(Status, _Fallback)   -> Status.

%% ============================================================
%% Helpers
%% ============================================================
nth(N, L) -> lists:nth(N, L).

%% ============================================================
%% Diagnostic log -- /run/lapee/splash.log
%% ============================================================
%% Append-only, per-event, and kept on tmpfs. The log records phase
%% transitions, the IP (already on screen) and probe error reasons --
%% no PSK, no SSID, no wallet material. All errors swallowed:
%% best-effort diagnostic, must never kill the splash itself.
log_start() ->
    catch file:write_file(log_path(),
        io_lib:format("[lapee-splash] started pid=~p t=~p~n",
                      [self(), erlang:monotonic_time(millisecond)]),
        [append]).

log_event(Msg) ->
    Line = io_lib:format("[lapee-splash] ~s~n",
                         [lists:flatten(Msg)]),
    catch file:write_file(log_path(), Line, [append]).
