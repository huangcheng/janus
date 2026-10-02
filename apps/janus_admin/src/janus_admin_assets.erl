%%%-------------------------------------------------------------------
%%% @doc Static assets for the admin SPA. `/admin` and `/admin/{spa
%%% route}` serve `priv/www/index.html`; real files under `priv/www`
%%% (e.g. `/admin/assets/app.js`, `/admin/icon.png`) are served
%%% directly. Path traversal is rejected.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_admin_assets).

-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    %% path_info is `undefined` for the exact "/admin" route.
    Segs = case cowboy_req:path_info(Req0) of
        undefined -> [];
        L when is_list(L) -> L
    end,
    Req =
        case resolve(segments_safe(Segs)) of
            {ok, RelPath} ->
                serve_file(RelPath, Req0);
            error ->
                cowboy_req:reply(400, #{}, <<"bad path">>, Req0)
        end,
    {ok, Req, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

segments_safe(Segs) ->
    lists:all(fun(S) -> is_binary(S) andalso binary:match(S, <<"..">>) =:= nomatch end, Segs)
        andalso Segs.

%% Real files win; anything else falls back to the SPA shell.
resolve([]) ->
    {ok, "index.html"};
resolve(Segs) ->
    Rel = string:join([binary_to_list(S) || S <- Segs], "/"),
    Full = filename:join(www_dir(), Rel),
    case filelib:is_regular(Full) of
        true -> {ok, Rel};
        false -> {ok, "index.html"}
    end.

serve_file(Rel, Req) ->
    Full = filename:join(www_dir(), Rel),
    case file:read_file(Full) of
        {ok, Bin} ->
            cowboy_req:reply(200, #{
                <<"content-type">> => mime(Rel),
                <<"cache-control">> => cache(Rel)
            }, Bin, Req);
        {error, _} ->
            Body = <<"admin UI assets are missing; run the SPA build (apps/janus_admin/spa)">>,
            cowboy_req:reply(404, #{<<"content-type">> => <<"text/plain">>}, Body, Req)
    end.

www_dir() ->
    filename:join(code:priv_dir(janus_admin), "www").

mime(Path) ->
    case filename:extension(Path) of
        <<".html">> -> <<"text/html; charset=utf-8">>;
        ".html" -> <<"text/html; charset=utf-8">>;
        <<".js">> -> <<"text/javascript; charset=utf-8">>;
        ".js" -> <<"text/javascript; charset=utf-8">>;
        <<".css">> -> <<"text/css; charset=utf-8">>;
        ".css" -> <<"text/css; charset=utf-8">>;
        <<".json">> -> <<"application/json">>;
        ".json" -> <<"application/json">>;
        <<".png">> -> <<"image/png">>;
        ".png" -> <<"image/png">>;
        <<".svg">> -> <<"image/svg+xml">>;
        ".svg" -> <<"image/svg+xml">>;
        <<".ico">> -> <<"image/x-icon">>;
        ".ico" -> <<"image/x-icon">>;
        <<".woff2">> -> <<"font/woff2">>;
        ".woff2" -> <<"font/woff2">>;
        <<".map">> -> <<"application/json">>;
        ".map" -> <<"application/json">>;
        <<".txt">> -> <<"text/plain; charset=utf-8">>;
        ".txt" -> <<"text/plain; charset=utf-8">>;
        _ -> <<"application/octet-stream">>
    end.

cache("index.html") -> <<"no-cache">>;
cache(_) -> <<"public, max-age=300">>.
