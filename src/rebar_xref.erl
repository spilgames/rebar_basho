%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009 Dave Smith (dizzyd@dizzyd.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%%
%% -------------------------------------------------------------------

%% -------------------------------------------------------------------
%% This module borrows heavily from http://github.com/etnt/exrefcheck project as
%% written by Torbjorn Tornkvist <tobbe@kreditor.se>, Daniel Luna and others.
%% -------------------------------------------------------------------
-module(rebar_xref).

-include("rebar.hrl").

-export([xref/2]).

%% ===================================================================
%% Public API
%% ===================================================================

xref(Config, _) ->
    %% Spin up xref
    {ok, _} = xref:start(xref),
    ok = xref:set_library_path(xref, code_path()),

    xref:set_default(xref, [{warnings,
                             rebar_config:get(Config, xref_warnings, false)},
                            {verbose, rebar_config:is_verbose()}]),

    {ok, _} = xref:add_directory(xref, "ebin"),

    %% Save the code path prior to doing anything
    OrigPath = code:get_path(),
    true = code:add_path(filename:join(rebar_utils:get_cwd(), "ebin")),

    %% Get list of xref checks we want to run
    ConfXrefChecks = rebar_config:get(Config, xref_checks,
                                  [exports_not_used,
                                   undefined_function_calls]),

    SupportedXrefs = [undefined_function_calls, undefined_functions, 
                        locals_not_used, exports_not_used,
                        deprecated_function_calls, deprecated_functions],

    XrefChecks = sets:to_list(sets:intersection(sets:from_list(SupportedXrefs), sets:from_list(ConfXrefChecks))),
    XrefNoWarn = xref_checks(XrefChecks),

    %% Run custom queries
    QueryChecks = rebar_config:get(Config, xref_queries, []),
    QueryNoWarn = lists:all(fun check_query/1, QueryChecks),

    %% Restore the original code path
    true = code:set_path(OrigPath),

    %% Stop xref
    stopped = xref:stop(xref),

    case lists:member(false, [XrefNoWarn, QueryNoWarn]) of
        true ->
            case rebar_config:get(Config, xref_strict, true) of
                true -> ?ABORT;
                false -> ?WARN("xref failed!", [])
            end;
        false ->
            ok
    end.

%%   ===================================================================
%% Internal functions
%% ===================================================================

xref_checks(XrefChecks) ->
    XrefWarnCount = lists:foldr(
        fun(XrefCheck, Acc) ->
            Results = check_xref(XrefCheck),
            FilteredResults =filter_xref_results(XrefCheck, Results),
            lists:foreach(fun({Type, Res}) -> display_xrefresult(Type, Res) end, FilteredResults),
            Acc + length(FilteredResults)
        end,
        0, XrefChecks),
    XrefWarnCount =:= 0.

check_xref(XrefCheck) ->
    {ok, Results} = xref:analyze(xref, XrefCheck),
    lists:map(fun(El) -> {XrefCheck, El} end, Results).

check_query({Query, Value}) ->
    {ok, Answer} = xref:q(xref, Query),
    case Answer =:= Value of
        false ->
            ?CONSOLE("Query ~s~n answer ~p~n did not match ~p~n",
                     [Query, Answer, Value]),
            false;
        _     ->
            true
    end.

code_path() ->
    [P || P <- code:get_path(),
          filelib:is_dir(P)] ++ [filename:join(rebar_utils:get_cwd(), "ebin")].

%%
%% Ignore behaviour functions, and explicitly marked functions
%%
%% Functions can be ignored by using
%% -ignore_xref([{F, A}, {M, F, A}...]).

filter_xref_results(XrefCheck, XrefResults) ->
    F = fun(Mod) ->
                Attrs = 
                    try
                        if 
                            Mod =:= undefined -> [];
                            true -> kf(attributes, Mod:module_info())
                        end                        
                    catch
                        _Class:_Error -> []
                    end,

                Ignore = kf(ignore_xref, Attrs),

                Additional = 
                    case XrefCheck of
                        exports_not_used -> [B:behaviour_info(callbacks) || B <- kf(behaviour, Attrs)];
                        _ -> []
                    end,

                lists:foldl(fun(El,Acc) ->
                                case El of
                                    {F, A} -> [{Mod,F,A} | Acc];
                                    {M, F, A} -> [{M,F,A} | Acc]
                                end
                            end, [], Ignore ++ lists:flatten(Additional))
    end,

    SearchModules = lists:usort(lists:map(
        fun(Res) ->
            case Res of   
                {_, {Ma,_Fa,_Aa}} -> Ma;
                {_, {{Ms,_Fs,_As},{_Mt,_Ft,_At}}} -> Ms;
                _ -> io:format("no match: ~p\n", [Res]), undefined                
            end
        end, XrefResults)),

    Ignore = lists:flatten(lists:map(F, SearchModules)),

    lists:foldr(
        fun(XrefResult, Acc) ->
            MFA = case XrefResult of                   
                {_, {_, MFAt}} -> MFAt;
                {_, MFAt} -> MFAt
            end, 
            case lists:member(MFA,Ignore) of
                false -> [XrefResult | Acc];
                _ -> Acc
            end
        end, [], XrefResults).

kf(Key, List) ->
    case lists:keyfind(Key, 1, List) of
        {Key, Value} ->
            Value;
        false ->
            []
    end.

display_xrefresult(Type, XrefResult) ->
    
    { {SFile, SLine}, SMFA, TMFA } = case XrefResult of
        {MFASource, MFATarget} -> {find_mfa_source(MFASource), format_fa(MFASource), format_mfa(MFATarget)};
        MFATarget -> { find_mfa_source(MFATarget), format_fa(MFATarget), undefined}
    end,
    case Type of
        undefined_function_calls -> 
            ?CONSOLE("~s:~w: Warning ~s calls undefined function ~s (Xref)\n", [SFile, SLine, SMFA, TMFA]);
        undefined_functions -> 
            ?CONSOLE("~s:~w: Warning ~s is undefined function (Xref)\n", [SFile, SLine, SMFA]);
        locals_not_used -> 
            ?CONSOLE("~s:~w: Warning ~s is unused local function (Xref)\n", [SFile, SLine, SMFA]);
        exports_not_used -> 
            ?CONSOLE("~s:~w: Warning ~s is unused export (Xref)\n", [SFile, SLine, SMFA]);
        deprecated_function_calls -> 
            ?CONSOLE("~s:~w: Warning ~s calls deprecated function ~s (Xref)\n", [SFile, SLine, SMFA, TMFA]); 
        deprecated_functions -> 
            ?CONSOLE("~s:~w: Warning ~s is deprecated function (Xref)\n", [SFile, SLine, SMFA]); 
        Other -> 
            ?CONSOLE("Warning ~s:~w: ~s - ~s xref check: ~s (Xref)\n", [SFile, SLine, SMFA, TMFA, Other])
    end.

format_mfa({M, F, A}) ->
    ?FMT("~s:~s/~w", [M, F, A]).

format_fa({_M, F, A}) ->
    ?FMT("~s/~w", [F, A]).

%%
%% Extract an element from a tuple, or undefined if N > tuple size
%%
safe_element(N, Tuple) ->
    case catch(element(N, Tuple)) of
        {'EXIT', {badarg, _}} ->
            undefined;
        Value ->
            Value
    end.

%%
%% Given a MFA, find the file and LOC where it's defined. Note that
%% xref doesn't work if there is no abstract_code, so we can avoid
%% being too paranoid here.
%%
find_mfa_source({M, F, A}) ->
    {M, Bin, _} = code:get_object_code(M),
    AbstractCode = beam_lib:chunks(Bin, [abstract_code]),
    {ok, {M, [{abstract_code, {raw_abstract_v1, Code}}]}} = AbstractCode,
    %% Extract the original source filename from the abstract code
    [{attribute, 1, file, {Source, _}} | _] = Code,
    %% Extract the line number for a given function def
    Fn = [E || E <- Code,
               safe_element(1, E) == function,
               safe_element(3, E) == F,
               safe_element(4, E) == A],
    case Fn of
        [{function, Line, F, _, _}] -> {Source, Line};
        %% do not crash if functions are exported, even though they
        %% are not in the source.
        %% parameterized modules add new/1 and instance/1 for example.
        [] -> {Source, function_not_found}
    end.
