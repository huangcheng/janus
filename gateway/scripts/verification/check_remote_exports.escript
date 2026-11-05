#!/usr/bin/env escript
%%
%% Cross-module export check: every `mod:fun(...)` call in the app sources
%% must name a function that module actually EXPORTS.
%%
%% Why this exists (incident 2026-11-05): janus_config called
%% janus_http_sup:idle_timeout_ms/0, which was module-internal. Erlang
%% resolves remote calls at RUNTIME, so this compiled cleanly and passed
%% 235 tests — then killed the master during boot with
%% {undef,[{janus_http_sup,idle_timeout_ms,[],[]}]} before the HTTP face
%% existed. Workers never take that path, so the fleet looked half-fine
%% and only the role that serves traffic died.
%%
%% Nothing else catches this class:
%%   - the compiler does not check remote arity/export;
%%   - EUnit only tests what someone thought to test;
%%   - the code reviewer only sees files the commit touched, and the
%%     CALLED module was an old file in that incident;
%%   - dialyzer needs a PLT, which CI does not build.
%%
%% Arity comes from the AST, not from a text heuristic: `erl_syntax` knows
%% exactly how many arguments a call has even when they span lines, so an
%% exported /1 and a missing /0 are distinguishable.
%%
%% Usage (from gateway/):  escript scripts/verification/check_remote_exports.escript
%% Exit 0 = clean, 1 = at least one unresolved call.
-mode(compile).

main(_) ->
    %% syntax_tools ships with OTP; locate it rather than hardcoding a
    %% per-machine path, so this runs on CI and on a developer box alike.
    _ = code:add_pathsa(filelib:wildcard(filename:join(code:lib_dir(), "syntax_tools-*/ebin"))),
    run().

run() ->
    Sources = filelib:wildcard("apps/*/src/*.erl"),
    Results = [check_file(Path) || Path <- Sources],
    Bad = lists:usort(lists:flatmap(fun({_Path, Findings}) -> Findings end, Results)),
    Errors = [E || {_P, {error, E}} <- Results],
    case {Errors, Bad} of
        {[_ | _], _} ->
            io:format("FAIL: could not parse~n"),
            lists:foreach(fun(E) -> io:format("  ~p~n", [E]) end, Errors),
            halt(1);
        {[], []} ->
            io:format("OK: ~p source files, every remote call resolves~n", [length(Sources)]),
            halt(0);
        {[], _} ->
            io:format("FAIL: ~p unresolved remote call(s)~n", [length(Bad)]),
            lists:foreach(fun report/1, Bad),
            halt(1)
    end.

report({Mod, Fun, Arity, File, Line}) ->
    io:format("  ~s:~p  ~s:~s/~p is not exported~n", [File, Line, Mod, Fun, Arity]).

check_file(Path) ->
    case epp_dodger:parse_file(Path, [{no_fail, true}]) of
        {ok, Forms} ->
            {Path, lists:flatmap(fun(F) -> calls_in(F, Path) end, Forms)};
        {error, Reason} ->
            {Path, {error, {Path, Reason}}}
    end.

%% Every remote call in one form, with the arity the AST reports.
calls_in(Form, Path) ->
    erl_syntax_lib:fold(
        fun(Node, Acc) ->
            case erl_syntax:type(Node) of
                application ->
                    case erl_syntax:application_operator(Node) of
                        Op when Op =/= none ->
                            case erl_syntax:type(Op) of
                                module_qualifier ->
                                    M = name(erl_syntax:module_qualifier_argument(Op)),
                                    F = name(erl_syntax:module_qualifier_body(Op)),
                                    A = length(erl_syntax:application_arguments(Node)),
                                    case unresolved(M, F, A) of
                                        true -> [{M, F, A, Path, line(Node)} | Acc];
                                        false -> Acc
                                    end;
                                _ ->
                                    Acc
                            end;
                        _ ->
                            Acc
                    end;
                _ ->
                    Acc
            end
        end,
        [],
        Form
    ).

name(Node) ->
    case erl_syntax:type(Node) of
        atom -> erl_syntax:atom_value(Node);
        _ -> undefined
    end.

line(Node) ->
    case erl_syntax:get_pos(Node) of
        {L, _C} -> L;
        L when is_integer(L) -> L;
        _ -> 0
    end.

unresolved(undefined, _F, _A) ->
    false;
unresolved(_M, undefined, _A) ->
    false;
unresolved(Mod, Fun, Arity) ->
    case exports_of(Mod) of
        unknown -> false;
        Exports -> not lists:member({Fun, Arity}, Exports)
    end.

%% Exports read from the SOURCE, so a stale _build cannot make this pass on
%% code that does not compile to what it claims.
exports_of(Mod) ->
    case find_source(Mod) of
        unknown ->
            unknown;
        Path ->
            case epp_dodger:parse_file(Path, [{no_fail, true}]) of
                {ok, Forms} -> lists:append([attribute_exports(F) || F <- Forms]);
                _ -> unknown
            end
    end.

find_source(Mod) ->
    Name = atom_to_list(Mod) ++ ".erl",
    case filelib:wildcard("apps/*/src/" ++ Name) of
        [Path | _] -> Path;
        [] -> unknown
    end.

attribute_exports(Form) ->
    case erl_syntax:type(Form) of
        attribute ->
            case atom_value(erl_syntax:attribute_name(Form)) of
                'export' -> export_specs(erl_syntax:attribute_arguments(Form));
                _ -> []
            end;
        _ ->
            []
    end.

export_specs([List]) ->
    [spec(Element) || Element <- erl_syntax:list_elements(List)];
export_specs(_) ->
    [].

spec(Element) ->
    case erl_syntax:type(Element) of
        arity_qualifier ->
            F = erl_syntax:arity_qualifier_body(Element),
            A = erl_syntax:arity_qualifier_argument(Element),
            {atom_value(F), int_value(A)};
        _ ->
            {undefined, undefined}
    end.

atom_value(Node) ->
    case erl_syntax:type(Node) of
        atom -> erl_syntax:atom_value(Node);
        _ -> undefined
    end.

int_value(Node) ->
    case erl_syntax:type(Node) of
        integer -> erl_syntax:integer_value(Node);
        _ -> undefined
    end.