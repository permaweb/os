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
                "qr"      -> qr;
                "max"     -> max;
                "full"    -> max;
                "deck"    -> deck;
                "sigil"   -> sigil;
                "blue"    -> blue;
                "orbit"   -> orbit;
                "matrix"  -> matrix;
                "plaque"  -> plaque;
                "provision" -> provision;
                "classic" -> classic;
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

%% Scale (chars per laptop-width unit) derived from terminal size:
%% target ~50% of screen width, capped so the lid never clips out
%% the top or footer at any yaw. Set LAPEE_SPLASH_SCALE=<float> to
%% override (useful when the auto-pick feels small on a HiDPI
%% framebuffer).
splash_scale(W, H) ->
    case os:getenv("LAPEE_SPLASH_SCALE") of
        false -> auto_scale(W, H);
        ""    -> auto_scale(W, H);
        Str ->
            try list_to_float(Str)
            catch _:_ ->
                try float(list_to_integer(Str))
                catch _:_ -> auto_scale(W, H)
                end
            end
    end.

auto_scale(W, H) ->
    %% 4 laptop-width units * Scale ≈ W/2, so Scale = W/8.
    %%
    %% Vertically: the look-down tilt mixes Z into projected Y, so
    %% the silhouette's row span depends on yaw. Worst-case Yt range
    %% across all yaws is ~4.54 units, halved by the 2:1 char aspect
    %% = 2.27*Scale rows. Reserve 5 rows for the footer + breathing
    %% room and cap Scale so the spinning silhouette never clips at
    %% any yaw.
    ScaleW = W / 8.0,
    ScaleH = max(2.0, (H - 5) / 2.3),
    max(4.0, min(ScaleW, ScaleH)).

%% Y-coordinate shift so the laptop's vertical midpoint sits at
%% ~0.45*H -- slightly above centre, so the footer below the base
%% has breathing room. Yaw-aware midpoint Yt is ~0.98 in tilt-space:
%%   Cy_mid = H/2 - 0.98*Scale/2 - Lift  ->  H*0.45
%%   Lift   = 0.05*H - 0.49*Scale
splash_lift(H, Scale) ->
    0.05 * H - 0.49 * Scale.

%% Status footer row -- below the laptop's bottom-most cell at any
%% yaw (which sits at ~0.85*H given the scale/lift above) with one
%% row of breathing room. Clamped so a tiny terminal still draws.
splash_status_row(H) ->
    max(1, min(H - 1, round(H * 0.92))).

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
    Grid = case {small_canvas(W, H), Layout} of
        {true, classic} -> render_classic_grid(W, H, Yaw, Lid, Footer);
        {true, _}       -> render_compact_grid(W, H, Yaw, Lid, Footer, Frame, Layout);
        {_, classic}    -> render_classic_grid(W, H, Yaw, Lid, Footer);
        {_, max}        -> render_max_grid(W, H, Yaw, Lid, Footer, Frame);
        {_, deck}       -> render_deck_grid(W, H, Yaw, Lid, Footer, Frame);
        {_, sigil}      -> render_sigil_grid(W, H, Yaw, Lid, Footer, Frame);
        {_, blue}       -> render_blue_grid(W, H, Yaw, Lid, Footer, Frame, Ip);
        {_, orbit}      -> render_orbit_grid(W, H, Yaw, Lid, Footer, Frame);
        {_, matrix}     -> render_matrix_grid(W, H, Yaw, Lid, Footer, Frame);
        {_, plaque}     -> render_plaque_grid(W, H, Yaw, Lid, Footer, Frame);
        {_, provision}  -> render_provision_grid(W, H, Yaw, Lid, Footer);
        _               -> render_qr_grid(W, H, Yaw, Lid, Footer, Frame, Ip)
    end,
    %% Emit: cursor home, theme colour, then row by row separated
    %% by CRLF. Every row is full-width, so old frame cells are
    %% overwritten without needing a full clear at 12 fps.
    Rows = [emit_row(Grid, W, R) || R <- lists:seq(1, H)],
    [<<"\e[H">>, theme_prefix(Layout, Phase, Frame),
     lists:join(<<"\r\n">>, Rows), <<"\e[0m">>].

render_classic_grid(W, H, Yaw, Lid, Footer) ->
    Scale = splash_scale(W, H),
    Lift  = splash_lift(H, Scale),
    Grid0 = draw_laptop(#{}, W, H, Yaw, Lid,
                        W / 2.0, H / 2.0 - Lift, Scale),
    overlay_centered(Grid0, W, splash_status_row(H), Footer).

small_canvas(W, H) ->
    W < 100 orelse H < 34.

render_compact_grid(W, H, Yaw, Lid, Footer, Frame, Layout) ->
    Seed = machine_seed(),
    Grid0 = scan_background(#{}, W, H, Frame, compact_step(Layout)),
    Scale = max(5.0, min(W / 6.2, (H - 7) / 2.25)),
    Grid1 = draw_laptop(Grid0, W, H, Yaw, Lid,
                        W / 2.0, H * 0.49, Scale),
    Grid1a = fill_rect(Grid1, W, H, 1, 1, W, 4),
    Grid2 = overlay_centered(Grid1a, W, 2, compact_title(Layout)),
    Grid3 = overlay_centered(Grid2, W, 4,
                             "PUBLIC ID " ++ fingerprint_label(Seed)),
    Grid3a = fill_rect(Grid3, W, H, 1, H - 7, W, 7),
    Grid4 = overlay_centered(Grid3a, W, H - 6,
                             compact_caption(Layout)),
    Grid5 = draw_progress(Grid4, W, H, 6, H - 4, W - 12, Frame, Footer),
    overlay_centered(Grid5, W, H - 2, Footer).

compact_title(qr)     -> "LapEE // public node sigil";
compact_title(max)    -> "LapEE // full-frame trust machine";
compact_title(deck)   -> "LapEE // boot deck";
compact_title(sigil)  -> "LapEE // machine sigil";
compact_title(blue)   -> ":) LapEE proof boot";
compact_title(orbit)  -> "LapEE // orbital proof field";
compact_title(matrix) -> "LapEE // measured boot stream";
compact_title(plaque) -> "LapEE // public compute object";
compact_title(_)      -> "LapEE // HyperBEAM node".

compact_caption(qr)     -> "TPM quote | PCR replay | node sigil";
compact_caption(max)    -> "TPM quote | PCR replay | AK bind";
compact_caption(deck)   -> "kernel locked | TPM live | HyperBEAM waking";
compact_caption(sigil)  -> "public-key pattern, no secrets";
compact_caption(blue)   -> "collecting measured boot proof";
compact_caption(orbit)  -> "AK orbit | quote live | route open";
compact_caption(matrix) -> "PCR0 ok | PCR4 ok | PCR15 ok";
compact_caption(plaque) -> "decentralized compute, visibly alive";
compact_caption(_)      -> "TPM-backed HyperBEAM node".

compact_step(blue)   -> 41;
compact_step(matrix) -> 13;
compact_step(orbit)  -> 29;
compact_step(_)      -> 23.

render_max_grid(W, H, Yaw, Lid, Footer, Frame) ->
    Scale = max_scale(W, H),
    Grid0 = scan_background(#{}, W, H, Frame, 17),
    Grid1 = draw_laptop(Grid0, W, H, Yaw, Lid,
                        W / 2.0, H * 0.50, Scale),
    Grid2 = draw_box(Grid1, W, H, 2, 2, W - 2, H - 2),
    Grid3 = overlay_text(Grid2, W, H, 4, 3,
                         "LAPEE // HYPERBEAM TRUST MACHINE"),
    Grid4 = overlay_centered(Grid3, W, 5,
                             "[ TPM QUOTE | PCR REPLAY | AK BIND | NODE MESSAGE ]"),
    Grid5 = draw_progress(Grid4, W, H, 6, H - 4, W - 12, Frame, Footer),
    overlay_centered(Grid5, W, H - 2, Footer).

render_qr_grid(W, H, Yaw, Lid, Footer, Frame, Ip) ->
    Mods = qr_modules(W, H),
    QrW = Mods * 2 + 2,
    QrH = Mods + 2,
    QrX = max(2, W - QrW - 2),
    QrY = max(3, H - QrH - 1),
    PanelW = min(42, max(28, W - QrX + 2)),
    PanelX = max(2, W - PanelW - 2),
    WorkRight = max(36, min(W - 4, PanelX - 3)),
    Scale = max(5.0, min(WorkRight / 5.5, (H - 8) / 2.15)),
    Grid0 = scan_background(#{}, W, H, Frame, 23),
    PanelH = max(9, QrY - 5),
    Grid1 = draw_laptop(Grid0, W, H, Yaw, Lid,
                        WorkRight / 2.0 + 1, H * 0.47, Scale),
    Grid2 = overlay_text(Grid1, W, H, 3, 2,
                         "LapEE / live attestation console"),
    Grid3 = draw_box(fill_rect(Grid2, W, H, PanelX + 1, 4,
                               PanelW - 2, PanelH - 2),
                     W, H, PanelX, 3, PanelW, PanelH),
    Url = case Ip of
        undefined -> "http://<node>:8734/";
        _         -> "http://" ++ Ip ++ ":8734/"
    end,
    Lines = ["HYPERBEAM BOOT",
             "> load dev_tpm2",
             "> quote PCR[0,2,4,8,15]",
             "> bind node message",
             "> public sigil (no secrets)",
             "> serve " ++ Url,
             "> " ++ status_word(Footer)],
    Grid4 = overlay_lines(Grid3, W, H, PanelX + 2, 5, Lines),
    Grid5 = draw_qr(Grid4, W, H, QrX, QrY, Mods),
    Grid6 = overlay_text(Grid5, W, H, QrX, max(1, QrY - 1),
                         "PUBLIC NODE SIGIL"),
    overlay_text(Grid6, W, H, 3, H - 2, Footer).

render_deck_grid(W, H, Yaw, Lid, Footer, Frame) ->
    RailW = min(32, max(24, W div 4)),
    Grid0 = scan_background(#{}, W, H, Frame, 11),
    Scale = max(5.0, min((W - RailW - 8) / 5.2, (H - 7) / 2.2)),
    Xc = RailW + (W - RailW) / 2.0,
    Grid1 = draw_laptop(Grid0, W, H, Yaw, Lid, Xc, H * 0.48, Scale),
    Grid2 = draw_box(fill_rect(Grid1, W, H, 3, 3, RailW - 2, H - 5),
                     W, H, 2, 2, RailW, H - 3),
    HbLine = case status_word(Footer) of
        "READY" -> "05 hyperbeam  ready";
        _       -> "05 hyperbeam  waking"
    end,
    Grid3 = overlay_lines(Grid2, W, H, 4, 4,
        ["BOOT DECK",
         "01 kernel     locked",
         "02 initramfs  sealed",
         "03 tpm quote  live",
         "04 pcr replay armed",
         HbLine,
         "",
         "mode: LAPEE",
         "net : dhcp -> node",
         "out : attestation only"]),
    Grid4 = overlay_text(Grid3, W, H, RailW + 4, 3,
                         "HYPERBEAM NODE ONLINE PATH"),
    Grid5 = draw_progress(Grid4, W, H, RailW + 4, H - 5,
                          W - RailW - 8, Frame, Footer),
    overlay_text(Grid5, W, H, RailW + 4, H - 3, Footer).

render_sigil_grid(W, H, Yaw, Lid, Footer, Frame) ->
    Seed = machine_seed(),
    Label = fingerprint_label(Seed),
    Grid0 = constellation_background(#{}, W, H, Seed, Frame, 29),
    Scale = max(7.0, min(W / 7.4, (H - 8) / 2.25)),
    Grid1 = draw_laptop(Grid0, W, H, Yaw, Lid,
                        W * 0.43, H * 0.49, Scale),
    PanelW = min(48, max(34, W div 3)),
    PanelH = min(31, max(22, H - 10)),
    PanelX = W - PanelW - 4,
    PanelY = 5,
    Grid2 = draw_box(fill_rect(Grid1, W, H, PanelX + 1, PanelY + 1,
                               PanelW - 2, PanelH - 2),
                     W, H, PanelX, PanelY, PanelW, PanelH),
    Grid3 = overlay_lines(Grid2, W, H, PanelX + 3, PanelY + 2,
        ["MACHINE SIGIL",
         "PUBLIC ID " ++ Label,
         "",
         "derived from public key material",
         "no secrets, no disk diagnostics"]),
    Grid4 = draw_sigil(Grid3, W, H, PanelX + 7, PanelY + 9,
                       17, 17, Seed, $#),
    Grid5 = overlay_text(Grid4, W, H, 4, 3,
                         "LapEE // this machine is awake"),
    Grid6 = draw_progress(Grid5, W, H, 4, H - 4, W - 8, Frame, Footer),
    overlay_text(Grid6, W, H, 4, H - 2, Footer).

render_blue_grid(W, H, Yaw, Lid, Footer, _Frame, Ip) ->
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

render_orbit_grid(W, H, Yaw, Lid, Footer, Frame) ->
    Seed = machine_seed(),
    Grid0 = constellation_background(#{}, W, H, Seed, Frame, 37),
    Xc = W / 2.0,
    Yc = H * 0.48,
    Grid1 = draw_orbit(Grid0, W, H, Xc, Yc, W * 0.31, H * 0.24, Frame, $.),
    Grid2 = draw_orbit(Grid1, W, H, Xc, Yc, W * 0.23, H * 0.16, Frame + 40, $+),
    Grid3 = draw_laptop(Grid2, W, H, Yaw, Lid, Xc, Yc,
                        max(6.0, min(W / 8.2, (H - 8) / 2.35))),
    Grid4 = overlay_centered(Grid3, W, 3,
                             "LapEE ORBITAL NODE // measured proof field"),
    Grid5 = overlay_centered(Grid4, W, H - 4,
                             "AK " ++ fingerprint_label(Seed) ++
                             "  |  TPM quote live  |  HyperBEAM route open"),
    overlay_centered(Grid5, W, H - 2, Footer).

render_matrix_grid(W, H, Yaw, Lid, Footer, Frame) ->
    Seed = machine_seed(),
    Grid0 = matrix_rain(#{}, W, H, Seed, Frame),
    Grid1 = draw_laptop(Grid0, W, H, Yaw, Lid,
                        W * 0.52, H * 0.50,
                        max(6.0, min(W / 6.8, (H - 8) / 2.2))),
    Grid2 = draw_box(fill_rect(Grid1, W, H, 4, 4, 36, 8),
                     W, H, 3, 3, 38, 10),
    Grid3 = overlay_lines(Grid2, W, H, 5, 5,
        ["MEASURED BOOT STREAM",
         "PCR0  firmware   ok",
         "PCR4  cmdline    ok",
         "PCR15 node bind  ok",
         "HB    serving"]),
    overlay_text(Grid3, W, H, 5, H - 2, Footer).

render_plaque_grid(W, H, Yaw, Lid, Footer, Frame) ->
    Seed = machine_seed(),
    Grid0 = constellation_background(#{}, W, H, Seed, Frame, 43),
    Grid1 = draw_laptop(Grid0, W, H, Yaw, Lid,
                        W * 0.38, H * 0.50,
                        max(6.0, min(W / 8.0, (H - 7) / 2.15))),
    PlaqueW = min(58, max(44, W div 3)),
    PlaqueX = W - PlaqueW - 6,
    Grid2 = draw_box(fill_rect(Grid1, W, H, PlaqueX + 1, 7,
                               PlaqueW - 2, 22),
                     W, H, PlaqueX, 6, PlaqueW, 24),
    Grid3 = overlay_lines(Grid2, W, H, PlaqueX + 3, 9,
        ["LAPEE",
         "PUBLIC COMPUTE OBJECT",
         "",
         "A measured HyperBEAM node.",
         "TPM-backed identity. Local proof.",
         "Decentralized compute, visibly alive.",
         "",
         "machine " ++ fingerprint_label(Seed)]),
    Grid4 = draw_sigil(Grid3, W, H, PlaqueX + 3, 21, 7, 17, Seed, $*),
    ProgressY = min(H - 6, 33),
    Grid4a = overlay_text(Grid4, W, H, PlaqueX + 3, 18,
                          "public key derived; no secrets displayed"),
    Grid5 = draw_progress(Grid4a, W, H, PlaqueX + 3, ProgressY,
                          PlaqueW - 8, Frame, Footer),
    overlay_text(Grid5, W, H, PlaqueX + 3, H - 3, Footer).

theme_prefix(qr, ready, _)      -> <<"\e[1;36m">>;
theme_prefix(qr, _, _)          -> <<"\e[0;36m">>;
theme_prefix(max, ready, _)     -> <<"\e[1;32m">>;
theme_prefix(max, _, _)         -> <<"\e[0;32m">>;
theme_prefix(deck, ready, _)    -> <<"\e[1;35m">>;
theme_prefix(deck, _, _)        -> <<"\e[0;35m">>;
theme_prefix(sigil, ready, _)   -> <<"\e[1;33m">>;
theme_prefix(sigil, _, _)       -> <<"\e[0;33m">>;
theme_prefix(blue, ready, _)    -> blue_theme_prefix();
theme_prefix(blue, _, _)        -> blue_theme_prefix();
theme_prefix(orbit, ready, _)   -> <<"\e[1;36m">>;
theme_prefix(orbit, _, _)       -> <<"\e[0;36m">>;
theme_prefix(matrix, ready, _)  -> <<"\e[1;32m">>;
theme_prefix(matrix, _, _)      -> <<"\e[0;32m">>;
theme_prefix(plaque, ready, _)  -> <<"\e[1;37m">>;
theme_prefix(plaque, _, _)      -> <<"\e[0;37m">>;
theme_prefix(provision, _, _)   -> provision_theme_prefix();
theme_prefix(classic, ready, _) -> <<"\e[1;37m">>;
theme_prefix(classic, _, _)     -> <<"\e[0;37m">>.

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

max_scale(W, H) ->
    max(6.0, min(W / 5.3, (H - 6) / 2.05)).

machine_fingerprint_source() ->
    case os:getenv("LAPEE_MACHINE_FINGERPRINT") of
        false ->
            case file:read_file("/run/lapee/machine-fingerprint") of
                {ok, Bin} ->
                    string:trim(binary_to_list(Bin));
                _ ->
                    "LAPEE-QEMU-PREVIEW-PUBLIC-AK"
            end;
        "" ->
            "LAPEE-QEMU-PREVIEW-PUBLIC-AK";
        Str ->
            Str
    end.

machine_seed() ->
    lists:foldl(
      fun(C, Acc) -> ((Acc * 131) + C) band 16#7fffffff end,
      16#4c415045,
      machine_fingerprint_source()).

fingerprint_label(Seed) ->
    string:uppercase(lists:flatten(io_lib:format("~8.16.0B", [Seed]))).

constellation_background(Grid, W, H, Seed, Frame, Step) ->
    Stars = [{star_x(W, Seed, I), star_y(H, Seed, I)}
             || I <- lists:seq(1, min(72, max(18, W div 2)))],
    G1 = lists:foldl(
           fun({X, Y}, G) ->
               Ch = case ((X + Y + Frame) rem Step) of
                   0 -> $+;
                   _ -> $.
               end,
               plot(G, W, H, X, Y, Ch)
           end,
           Grid,
           Stars),
    Links = lists:seq(1, min(14, length(Stars) - 1)),
    lists:foldl(
      fun(I, G) ->
          case (I + Frame div 24) rem 3 of
              0 ->
                  P1 = lists:nth(I, Stars),
                  P2 = lists:nth(I + 1, Stars),
                  draw_line(G, W, H, P1, P2);
              _ ->
                  G
          end
      end,
      G1,
      Links).

star_x(W, Seed, I) ->
    1 + ((Seed + I * 37 + I * I * 11) rem max(1, W)).

star_y(H, Seed, I) ->
    1 + ((Seed div 7 + I * 29 + I * I * 5) rem max(1, H)).

draw_sigil(Grid0, W, H, X, Y, Rows, Cols, Seed, Ch) ->
    Cells = [{R, C} || R <- lists:seq(0, Rows - 1),
                       C <- lists:seq(0, Cols - 1),
                       sigil_dark(Seed, Rows, Cols, R, C)],
    lists:foldl(
      fun({R, C}, G) ->
          X0 = X + C * 2,
          Y0 = Y + R,
          plot(plot(G, W, H, X0, Y0, Ch), W, H, X0 + 1, Y0, Ch)
      end,
      Grid0,
      Cells).

sigil_dark(Seed, Rows, Cols, R, C) ->
    HalfC = Cols div 2,
    C1 = if C > HalfC -> Cols - 1 - C; true -> C end,
    Mid = (R =:= Rows div 2) orelse (C =:= HalfC),
    V = (Seed + R * 1103 + C1 * 1973 + R * C1 * 89) rem 31,
    Mid orelse V < 11.

draw_orbit(Grid0, W, H, Xc, Yc, Rx, Ry, Frame, Ch) ->
    Angles = lists:seq(0, 354, 6),
    G1 = lists:foldl(
           fun(A0, G) ->
               A = (A0 + Frame) * math:pi() / 180.0,
               X = round(Xc + Rx * math:cos(A)),
               Y = round(Yc + Ry * math:sin(A)),
               plot(G, W, H, X, Y, Ch)
           end,
           Grid0,
           Angles),
    Sweep = (Frame * 4) rem 360,
    A = Sweep * math:pi() / 180.0,
    draw_line(G1, W, H,
              {round(Xc), round(Yc)},
              {round(Xc + Rx * math:cos(A)),
               round(Yc + Ry * math:sin(A))}).

matrix_rain(Grid, W, H, Seed, Frame) ->
    Glyphs = "01AKPCRHB8734",
    lists:foldl(
      fun(C, G0) ->
          Phase = (Seed + C * 17 + Frame) rem max(1, H),
          lists:foldl(
            fun(K, G) ->
                R = 1 + ((Phase + K * 7) rem max(1, H)),
                Index = 1 + ((Seed + C * 3 + R + K) rem length(Glyphs)),
                Ch = lists:nth(Index, Glyphs),
                plot(G, W, H, C, R, Ch)
            end,
            G0,
            lists:seq(0, 2))
      end,
      Grid,
      lists:seq(2, W - 1, 4)).

emit_row(Grid, W, Row) ->
    [maps:get({Row, Col}, Grid, $\s) || Col <- lists:seq(1, W)].

overlay_centered(Grid, W, Row, Text) ->
    Pad = max(0, (W - length(Text)) div 2),
    lists:foldl(
      fun({I, Ch}, G) ->
          plot(G, W, 1000, Pad + I + 1, Row, Ch)
      end,
      Grid,
      lists:zip(lists:seq(0, length(Text) - 1), Text)).

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

draw_box(Grid, W, H, X, Y, BW, BH) when BW >= 2, BH >= 2 ->
    X2 = X + BW - 1,
    Y2 = Y + BH - 1,
    G1 = draw_hline(Grid, W, H, X + 1, X2 - 1, Y, $-),
    G2 = draw_hline(G1, W, H, X + 1, X2 - 1, Y2, $-),
    G3 = draw_vline(G2, W, H, X, Y + 1, Y2 - 1, $|),
    G4 = draw_vline(G3, W, H, X2, Y + 1, Y2 - 1, $|),
    plot(plot(plot(plot(G4, W, H, X, Y, $+), W, H, X2, Y, $+),
              W, H, X, Y2, $+), W, H, X2, Y2, $+);
draw_box(Grid, _, _, _, _, _, _) ->
    Grid.

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

draw_hline(Grid, W, H, X1, X2, Y, Ch) ->
    lists:foldl(fun(X, G) -> plot(G, W, H, X, Y, Ch) end,
                Grid, lists:seq(min(X1, X2), max(X1, X2))).

draw_vline(Grid, W, H, X, Y1, Y2, Ch) ->
    lists:foldl(fun(Y, G) -> plot(G, W, H, X, Y, Ch) end,
                Grid, lists:seq(min(Y1, Y2), max(Y1, Y2))).

draw_progress(Grid, W, H, X, Y, Len0, Frame) ->
    Len = max(8, Len0),
    G1 = overlay_text(Grid, W, H, X, Y, "["),
    G2 = overlay_text(G1, W, H, X + Len + 1, Y, "]"),
    Pos = Frame rem Len,
    lists:foldl(
      fun(I, G) ->
          Ch = case I of
              Pos -> $>;
              _ when I < Pos -> $=;
              _ -> $.
          end,
          plot(G, W, H, X + I + 1, Y, Ch)
      end,
      G2,
      lists:seq(0, Len - 1)).

draw_progress(Grid, W, H, X, Y, Len0, Frame, Footer) ->
    case status_word(Footer) of
        "READY" ->
            draw_complete_progress(Grid, W, H, X, Y, Len0);
        _ ->
            draw_progress(Grid, W, H, X, Y, Len0, Frame)
    end.

draw_complete_progress(Grid, W, H, X, Y, Len0) ->
    Len = max(8, Len0),
    G1 = overlay_text(Grid, W, H, X, Y, "["),
    G2 = overlay_text(G1, W, H, X + Len + 1, Y, "]"),
    lists:foldl(
      fun(I, G) -> plot(G, W, H, X + I + 1, Y, $=) end,
      G2,
      lists:seq(0, Len - 1)).

scan_background(Grid, W, H, Frame, Step) ->
    lists:foldl(
      fun(R, G0) ->
          lists:foldl(
            fun(C, G) ->
                case ((R * 3 + C * 5 + Frame) rem Step) of
                    0 -> plot(G, W, H, C, R, $.);
                    _ -> G
                end
            end,
            G0,
            lists:seq(1, W))
      end,
      Grid,
      lists:seq(1, H)).

qr_modules(W, H) ->
    if
        W >= 118 andalso H >= 42 -> 21;
        W >= 96  andalso H >= 34 -> 17;
        true -> 13
    end.

draw_qr(Grid0, W, H, X, Y, Mods) ->
    G0 = fill_rect(Grid0, W, H, X + 1, Y + 1, Mods * 2, Mods),
    G1 = draw_box(G0, W, H, X, Y, Mods * 2 + 2, Mods + 2),
    Cells = [{R, C} || R <- lists:seq(0, Mods - 1),
                       C <- lists:seq(0, Mods - 1),
                       qr_dark(Mods, R, C)],
    lists:foldl(
      fun({R, C}, G) ->
          X0 = X + 1 + C * 2,
          Y0 = Y + 1 + R,
          plot(plot(G, W, H, X0, Y0, $#), W, H, X0 + 1, Y0, $#)
      end,
      G1,
      Cells).

qr_dark(Mods, R, C) ->
    case finder_pos(Mods, R, C) of
        {true, FR, FC} ->
            finder_dark(FR, FC);
        false ->
            A = (R * 11 + C * 7 + R * C) rem 17,
            B = (R + C * 3) rem 5,
            A < 7 orelse B =:= 0
    end.

finder_pos(_Mods, R, C) when R < 7, C < 7 ->
    {true, R, C};
finder_pos(Mods, R, C) when R < 7, C >= Mods - 7 ->
    {true, R, C - (Mods - 7)};
finder_pos(Mods, R, C) when R >= Mods - 7, C < 7 ->
    {true, R - (Mods - 7), C};
finder_pos(_, _, _) ->
    false.

finder_dark(R, C) ->
    R =:= 0 orelse R =:= 6 orelse C =:= 0 orelse C =:= 6 orelse
    (R >= 2 andalso R =< 4 andalso C >= 2 andalso C =< 4).

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
