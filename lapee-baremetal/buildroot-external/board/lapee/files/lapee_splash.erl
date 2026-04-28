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
probe_path()       -> os:getenv("LAPEE_PROBE_PATH",  "/~tpm2@2.0a/info").
log_path()         -> os:getenv("LAPEE_SPLASH_LOG",  "/run/lapee/splash.log").

splash_layout() ->
    case os:getenv("LAPEE_SPLASH_LAYOUT") of
        false -> qr;
        ""    -> qr;
        Str ->
            case string:lowercase(Str) of
                "qr"      -> qr;
                "max"     -> max;
                "full"    -> max;
                "deck"    -> deck;
                "classic" -> classic;
                _         -> qr
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
poll_state(S = #{phase := Phase, ip := _Ip}) ->
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

%% Returns `true' when /info answered with HTTP 200, or
%% `{false, Reason}' otherwise. The Reason is a short human-readable
%% string suitable for splash.log -- not for screen.
%%
%% Speaks HTTP/1.0 over a raw gen_tcp connection rather than going
%% through inets/httpc. The probe URL contains both `~' and `@'
%% (e.g. `/~tpm2@2.0a/info'); httpc URL parsing throws on that pair
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
        true  -> Grid#{{Y, X} => Ch};
        false -> Grid
    end.

%% ============================================================
%% Frame composition + ANSI emission
%% ============================================================
render(#{cols := W, rows := H, layout := Layout, frame := Frame,
         yaw := Yaw, lid := Lid, phase := Phase, ip := Ip,
         hb_wait_t0 := HbT0}) ->
    Footer = footer_text(Phase, Ip, HbT0),
    Grid = case Layout of
        classic -> render_classic_grid(W, H, Yaw, Lid, Footer);
        max     -> render_max_grid(W, H, Yaw, Lid, Footer, Frame);
        deck    -> render_deck_grid(W, H, Yaw, Lid, Footer, Frame);
        _       -> render_qr_grid(W, H, Yaw, Lid, Footer, Frame, Ip)
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
    Grid5 = draw_progress(Grid4, W, H, 6, H - 4, W - 12, Frame),
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
             "> serve " ++ Url,
             "> " ++ status_word(Footer)],
    Grid4 = overlay_lines(Grid3, W, H, PanelX + 2, 5, Lines),
    Grid5 = draw_qr(Grid4, W, H, QrX, QrY, Mods),
    Grid6 = overlay_text(Grid5, W, H, QrX, max(1, QrY - 1),
                         "SCAN NODE"),
    overlay_text(Grid6, W, H, 3, H - 2, Footer).

render_deck_grid(W, H, Yaw, Lid, Footer, Frame) ->
    RailW = min(32, max(24, W div 4)),
    Grid0 = scan_background(#{}, W, H, Frame, 11),
    Scale = max(5.0, min((W - RailW - 8) / 5.2, (H - 7) / 2.2)),
    Xc = RailW + (W - RailW) / 2.0,
    Grid1 = draw_laptop(Grid0, W, H, Yaw, Lid, Xc, H * 0.48, Scale),
    Grid2 = draw_box(fill_rect(Grid1, W, H, 3, 3, RailW - 2, H - 5),
                     W, H, 2, 2, RailW, H - 3),
    Grid3 = overlay_lines(Grid2, W, H, 4, 4,
        ["BOOT DECK",
         "01 kernel     locked",
         "02 initramfs  sealed",
         "03 tpm quote  live",
         "04 pcr replay armed",
         "05 hyperbeam  waking",
         "",
         "mode: LAPEE",
         "net : dhcp -> node",
         "out : attestation only"]),
    Grid4 = overlay_text(Grid3, W, H, RailW + 4, 3,
                         "HYPERBEAM NODE ONLINE PATH"),
    Grid5 = draw_progress(Grid4, W, H, RailW + 4, H - 5,
                          W - RailW - 8, Frame),
    overlay_text(Grid5, W, H, RailW + 4, H - 3, Footer).

theme_prefix(qr, ready, _)      -> <<"\e[1;36m">>;
theme_prefix(qr, _, _)          -> <<"\e[0;36m">>;
theme_prefix(max, ready, _)     -> <<"\e[1;32m">>;
theme_prefix(max, _, _)         -> <<"\e[0;32m">>;
theme_prefix(deck, ready, _)    -> <<"\e[1;35m">>;
theme_prefix(deck, _, _)        -> <<"\e[0;35m">>;
theme_prefix(classic, ready, _) -> <<"\e[1;37m">>;
theme_prefix(classic, _, _)     -> <<"\e[0;37m">>.

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
        "starting HyperBEAM" ++ _ -> "HB STARTING";
        "network up" ++ _ -> "NETWORK UP";
        _ -> "BOOTING"
    end.

%% Status line texts -- the only words the operator sees on screen
%% during boot. In `hb-wait' we surface the IP + an elapsed-seconds
%% counter so a slow HB cold-start is visibly progressing rather
%% than indistinguishable from a hang.
footer_text(boot, _, _)              -> "starting LapEE...";
footer_text('net-up', undefined, _)  -> "network up; starting HyperBEAM...";
footer_text('net-up', Ip, _)         -> "network up (" ++ Ip ++ "); starting HyperBEAM...";
footer_text('hb-wait', undefined, _) -> "starting HyperBEAM...";
footer_text('hb-wait', Ip, undefined) ->
    "starting HyperBEAM... " ++ Ip;
footer_text('hb-wait', Ip, HbT0) ->
    Now = erlang:monotonic_time(millisecond),
    Secs = (Now - HbT0) div 1000,
    "starting HyperBEAM... " ++ Ip ++
        " (" ++ integer_to_list(Secs) ++ "s)";
footer_text(ready, undefined, _)     -> "Running.";
footer_text(ready, Ip, _)            -> "Running at http://" ++ Ip ++ ":8734/";
footer_text(_, _, _)                 -> "".

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
