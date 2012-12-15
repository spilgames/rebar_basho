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
%% -------------------------------------------------------------------
-module(rebar_deps).

-include_lib("kernel/include/file.hrl").
-include("rebar.hrl").

-export([preprocess/2,
         postprocess/2,
         compile/2,
         setup_env/1,
         'check-deps'/2,
         'get-deps'/2,
         'update-deps'/2,
         'delete-deps'/2,
         'list-deps'/2]).

-record(dep, { dir,
               app,
               vsn_regex,
               source,
               is_raw }). %% is_raw = true means non-Erlang/OTP dependency

%% ===================================================================
%% Public API
%% ===================================================================

preprocess(Config, _) ->
    %% Side effect to set deps_dir globally for all dependencies from
    %% top level down. Means the root deps_dir is honoured or the default
    %% used globally since it will be set on the first time through here
    Config1 = set_shared_deps_dir(Config, get_shared_deps_dir(Config, [])),
    %% We also set a shared_deps_dir. If set, we use this to download
    %% dependencies and then symlink from deps_dir to shared_deps_dir
    Config2 = set_global_deps_dir(Config,
        rebar_config:get_global(Config1, deps_dir, [])),

    %% Get the list of deps for the current working directory and identify those
    %% deps that are available/present.
    Deps = rebar_config:get_local(Config2, deps, []),
    {Config3, {AvailableDeps, MissingDeps}} = find_deps(Config2, find, Deps),

    ?DEBUG("Available deps: ~p\n", [AvailableDeps]),
    ?DEBUG("Missing deps  : ~p\n", [MissingDeps]),

    %% Add available deps to code path
    Config4 = update_deps_code_path(Config3, AvailableDeps),

    %% If skip_deps=true, mark each dep dir as a skip_dir w/ the core so that
    %% the current command doesn't run on the dep dir. However, pre/postprocess
    %% WILL run (and we want it to) for transitivity purposes.
    %%
    %% Also, if skip_deps=comma,separated,app,list, then only the given
    %% dependencies are skipped.
    NewConfig = case rebar_config:get_global(Config4, skip_deps, false) of
        "true" ->
            lists:foldl(
                fun(#dep{dir = Dir}, C) ->
                        rebar_config:set_skip_dir(C, Dir)
                end, Config4, AvailableDeps);
        Apps when is_list(Apps) ->
            SkipApps = [list_to_atom(App) || App <- string:tokens(Apps, ",")],
            lists:foldl(
                fun(#dep{dir = Dir, app = App}, C) ->
                        case lists:member(App, SkipApps) of
                            true -> rebar_config:set_skip_dir(C, Dir);
                            false -> C
                        end
                end, Config4, AvailableDeps);
        _ ->
            Config4
    end,

    %% Filtering out 'raw' dependencies so that no commands other than
    %% deps-related can be executed on their directories.
    NonRawAvailableDeps = [D || D <- AvailableDeps, not D#dep.is_raw],

    %% Return all the available dep directories for process
    {ok, NewConfig, dep_dirs(NonRawAvailableDeps)}.

postprocess(Config, _) ->
    case rebar_config:get_xconf(Config, ?MODULE, undefined) of
        undefined ->
            {ok, []};
        Dirs ->
            NewConfig = rebar_config:erase_xconf(Config, ?MODULE),
            {ok, NewConfig, Dirs}
    end.

compile(Config, _) ->
    {Config1, _AvailDeps} = do_check_deps(Config),
    {ok, Config1}.

%% set REBAR_DEPS_DIR and ERL_LIBS environment variables
setup_env(Config) ->
    {true, DepsDir} = get_deps_dir(Config),
    %% include rebar's DepsDir in ERL_LIBS
    Separator = case os:type() of
                    {win32, nt} ->
                        ";";
                    _ ->
                        ":"
                end,
    ERL_LIBS = case os:getenv("ERL_LIBS") of
                   false ->
                       {"ERL_LIBS", DepsDir};
                   PrevValue ->
                       {"ERL_LIBS", DepsDir ++ Separator ++ PrevValue}
               end,
    [{"REBAR_DEPS_DIR", DepsDir}, ERL_LIBS].

%% Set symlinks from DEPS dir to SHARED_DEPS dir
%% This works most Unix systems and Windows beginning with Vista
%% We need to make sure the deps_dir actually exists before
%% we can symlink to it
'symlink-shared-deps-to-deps'(Config, DownloadDir, TargetDir) ->
    {true, DepsDir} = get_deps_dir(Config),
    ok = filelib:ensure_dir(DepsDir ++ "/"),
    LinkResult = file:make_symlink(DownloadDir, TargetDir),
    case LinkResult of
        {error, enotsup} ->
            ?ABORT("Shared deps require OS support for symlinks.\n", []);
        ok ->
            ?DEBUG("Symlinked ~1000p to ~1000p\n", [DownloadDir, TargetDir]);
        _ ->
            ?ERROR("Error symlinking ~1000p to ~1000p : ~1000p\n", [DownloadDir, TargetDir, LinkResult])
    end,
    LinkResult.

%% Copy instead of symlink from SHARED_DEPS to DEPS dir
'copy-shared-deps-to-deps'(Config, DownloadDir, TargetDir) ->
    {true, DepsDir} = get_deps_dir(Config),
    ok = filelib:ensure_dir(DepsDir ++ "/"),
    Result = rebar_file_utils:cp_r([DownloadDir], TargetDir),
    ?DEBUG("Copied ~1000p to ~1000p\n", [DownloadDir, TargetDir]),
    Result.


setup_deps_dir(Config, SharedTargetDir, TargetDir) ->
    case rebar_config:get_global(Config, copy_from_shared_deps_dir, false) of
        true ->
            'copy-shared-deps-to-deps'(Config, SharedTargetDir, TargetDir);
        _ ->    %undefined | false
            'symlink-shared-deps-to-deps'(Config, SharedTargetDir, TargetDir)
    end.

%% common function used by 'check-deps' and 'compile'
do_check_deps(Config) ->
    %% Get the list of immediate (i.e. non-transitive) deps that are missing
    Deps = rebar_config:get_local(Config, deps, []),
    case find_deps(Config, find, Deps) of
        {Config1, {AvailDeps, []}} ->
            %% No missing deps
            {Config1, AvailDeps};
        {_Config1, {_, MissingDeps}} ->
            lists:foreach(fun (#dep{app=App, vsn_regex=Vsn, source=Src}) ->
                                  ?CONSOLE("Dependency not available: "
                                           "~p-~s (~p)\n", [App, Vsn, Src])
                          end, MissingDeps),
            ?FAIL
    end.

'check-deps'(Config, _) ->
    {Config1, AvailDeps} = do_check_deps(Config),
    {ok, save_dep_dirs(Config1, AvailDeps)}.

'get-deps'(Config, _) ->
    %% Determine what deps are available and missing
    Deps = rebar_config:get_local(Config, deps, []),
    {Config1, {_AvailableDeps, MissingDeps}} = find_deps(Config, find, Deps),
    MissingDeps1 = [D || D <- MissingDeps, D#dep.source =/= undefined],

    %% For each missing dep with a specified source, try to pull it.
    {Config2, PulledDeps} =
        lists:foldl(fun(D, {C, PulledDeps0}) ->
                            {C1, D1} = use_source(C, D),
                            {C1, [D1 | PulledDeps0]}
                    end, {Config1, []}, MissingDeps1),

    %% Add each pulled dep to our list of dirs for post-processing. This yields
    %% the necessary transitivity of the deps
    {ok, save_dep_dirs(Config2, lists:reverse(PulledDeps))}.

'update-deps'(Config, _) ->
    %% Determine what deps are required
    RawDeps = rebar_config:get_local(Config, deps, []),
    {Config1, Deps} = find_deps(Config, read, RawDeps),

    %% Update each dep
    UpdatedDeps = [update_source(Config1, D)
                   || D <- Deps, D#dep.source =/= undefined],

    %% Add each updated dep to our list of dirs for post-processing. This yields
    %% the necessary transitivity of the deps
    {ok, save_dep_dirs(Config1, UpdatedDeps)}.

'delete-deps'(Config, _) ->
    %% Delete all the available deps in our deps/ directory, if any
    {true, DepsDir} = get_deps_dir(Config),
    Deps = rebar_config:get_local(Config, deps, []),
    {Config1, {AvailableDeps, _}} = find_deps(Config, find, Deps),
    _ = [delete_dep(Config1, D) ||
        D <- AvailableDeps, lists:prefix(DepsDir, D#dep.dir)],
    {ok, Config1}.

'list-deps'(Config, _) ->
    Deps = rebar_config:get_local(Config, deps, []),
    case find_deps(Config, find, Deps) of
        {Config1, {AvailDeps, []}} ->
            lists:foreach(fun(Dep) -> print_source(Dep) end, AvailDeps),
            {ok, save_dep_dirs(Config1, AvailDeps)};
        {_, MissingDeps} ->
            ?ABORT("Missing dependencies: ~p\n", [MissingDeps])
    end.

%% ===================================================================
%% Internal functions
%% ===================================================================

%% Added because of trans deps,
%% need all deps in same dir and should be the one set by the root rebar.config
%% Sets a default if root config has no deps_dir set
set_shared_deps_dir(Config, []) ->
    GlobalDepsDir = rebar_config:get_global(Config, deps_dir, "deps"),
    DepsDir = rebar_config:get_local(Config, deps_dir, GlobalDepsDir),
    rebar_config:set_xconf(Config, deps_dir, DepsDir);
set_shared_deps_dir(Config, _DepsDir) ->
    Config.

get_deps_dir(Config) ->
    get_deps_dir(Config, "").

get_deps_dir(Config, App) ->
    BaseDir = rebar_config:get_xconf(Config, base_dir, []),
    DepsDir = get_shared_deps_dir(Config, "deps"),
    {true, filename:join([BaseDir, DepsDir, App])}.

%% shared_deps_dir by default is undefined.
%% By default it will use OS environment value REBAR_SHARED_DEPS_DIR if set.
set_global_deps_dir(Config, []) ->
    Config1 = rebar_config:set_global(Config, deps_dir,
                            rebar_config:get_local(Config, deps_dir, "deps")),

    EnvSharedDepsDir = case os:getenv("REBAR_SHARED_DEPS_DIR") of
                           false ->
                                undefined;
                           Dir ->
                                Dir
                       end,
    Config2 = rebar_config:set_global(Config1, shared_deps_dir,
        rebar_config:get_local(Config1, shared_deps_dir, EnvSharedDepsDir)),

    EnvCopyFromSharedDepsDir =
    case os:getenv("REBAR_COPY_FROM_SHARED_DEPS_DIR") of
        "1" -> true;
        "true" -> true;
        _ -> false
    end,

    rebar_config:set_global(Config2, copy_from_shared_deps_dir,
        rebar_config:get_local(Config2, copy_from_shared_deps_dir,
            EnvCopyFromSharedDepsDir));

set_global_deps_dir(Config, _DepsDir) ->
    Config.

dep_dirs(Deps) ->
    [D#dep.dir || D <- Deps].

save_dep_dirs(Config, Deps) ->
    rebar_config:set_xconf(Config, ?MODULE, dep_dirs(Deps)).

get_shared_deps_dir(Config, Default) ->
    rebar_config:get_xconf(Config, deps_dir, Default).

get_spil_shared_deps_dir(Config, Dep) ->
    BaseDir = rebar_config:get_global(Config, base_dir, []),
    SharedDepsDir = rebar_config:get_global(Config, shared_deps_dir, undefined),
    case SharedDepsDir of
        undefined ->
            {false, undefined};
        _ ->
            Version = parse_version(Dep#dep.source),
            UnversionedAppDir = filename:join(
                [BaseDir, SharedDepsDir, Dep#dep.app]),
            VersionedAppDir = get_download_dir(UnversionedAppDir, Version),
            {true, VersionedAppDir}
    end.

get_lib_dir(App) ->
    %% Find App amongst the reachable lib directories
    %% Returns either the found path or a tagged tuple with a boolean
    %% to match get_deps_dir's return type
    case code:lib_dir(App) of
        {error, bad_name} -> {false, bad_name};
        Path -> {true, Path}
    end.

update_deps_code_path(Config, []) ->
    Config;
update_deps_code_path(Config, [Dep | Rest]) ->
    Config2 =
        case is_app_available(Config, Dep#dep.app,
                              Dep#dep.vsn_regex, Dep#dep.dir, Dep#dep.is_raw) of
            {Config1, {true, _}} ->
                Dir = filename:join(Dep#dep.dir, "ebin"),
                ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
                ?DEBUG("Adding ~s to code path~n", [Dir]),
                true = code:add_patha(Dir),
                Config1;
            {Config1, {false, _}} ->
                Config1
        end,
    update_deps_code_path(Config2, Rest).

find_deps(Config, find=Mode, Deps) ->
    find_deps(Config, Mode, Deps, {[], []});
find_deps(Config, read=Mode, Deps) ->
    find_deps(Config, Mode, Deps, []).

find_deps(Config, find, [], {Avail, Missing}) ->
    {Config, {lists:reverse(Avail), lists:reverse(Missing)}};
find_deps(Config, read, [], Deps) ->
    {Config, lists:reverse(Deps)};
find_deps(Config, Mode, [App | Rest], Acc) when is_atom(App) ->
    find_deps(Config, Mode, [{App, ".*", undefined} | Rest], Acc);
find_deps(Config, Mode, [{App, VsnRegex} | Rest], Acc) when is_atom(App) ->
    find_deps(Config, Mode, [{App, VsnRegex, undefined} | Rest], Acc);
find_deps(Config, Mode, [{App, VsnRegex, Source} | Rest], Acc) ->
    find_deps(Config, Mode, [{App, VsnRegex, Source, []} | Rest], Acc);
find_deps(Config, Mode, [{App, VsnRegex, Source, Opts} | Rest], Acc) when is_list(Opts) ->
    Dep = #dep { app = App,
                 vsn_regex = VsnRegex,
                 source = Source,
                 %% dependency is considered raw (i.e. non-Erlang/OTP) when
                 %% 'raw' option is present
                 is_raw = proplists:get_value(raw, Opts, false) },
    {Config1, {Availability, FoundDir}} = find_dep(Config, Dep),
    find_deps(Config1, Mode, Rest,
              acc_deps(Mode, Availability, Dep, FoundDir, Acc));
find_deps(_Config, _Mode, [Other | _Rest], _Acc) ->
    ?ABORT("Invalid dependency specification ~p in ~s\n",
           [Other, rebar_utils:get_cwd()]).

find_dep(Config, Dep) ->
    %% Find a dep based on its source,
    %% e.g. {git, "https://github.com/mochi/mochiweb.git", "HEAD"}
    %% Deps with a source must be found (or fetched) locally.
    %% Those without a source may be satisfied from lib dir (get_lib_dir).
    find_dep(Config, Dep, Dep#dep.source).

find_dep(Config, Dep, undefined) ->
    %% 'source' is undefined.  If Dep is not satisfied locally,
    %% go ahead and find it amongst the lib_dir's.
    case find_dep_in_dir(Config, Dep, get_deps_dir(Config, Dep#dep.app)) of
        {_Config1, {avail, _Dir}} = Avail ->
            Avail;
        {Config1, {missing, _}} ->
            find_dep_in_dir(Config1, Dep, get_lib_dir(Dep#dep.app))
    end;
find_dep(Config, Dep, _Source) ->
    %% _Source is defined.  Regardless of what it is, we must find it
    %% locally satisfied or fetch it from the original source
    %% into the project's deps
    find_dep_in_dir(Config, Dep, get_deps_dir(Config, Dep#dep.app)).

find_dep_in_dir(Config, _Dep, {false, Dir}) ->
    {Config, {missing, Dir}};
find_dep_in_dir(Config, Dep, {true, Dir}) ->
    App = Dep#dep.app,
    VsnRegex = Dep#dep.vsn_regex,
    IsRaw = Dep#dep.is_raw,
    case is_app_available(Config, App, VsnRegex, Dir, IsRaw) of
        {Config1, {true, _AppFile}} -> {Config1, {avail, Dir}};
        {Config1, {false, _}}       -> {Config1, {missing, Dir}}
    end.

acc_deps(find, avail, Dep, AppDir, {Avail, Missing}) ->
    {[Dep#dep { dir = AppDir } | Avail], Missing};
acc_deps(find, missing, Dep, AppDir, {Avail, Missing}) ->
    {Avail, [Dep#dep { dir = AppDir } | Missing]};
acc_deps(read, _, Dep, AppDir, Acc) ->
    [Dep#dep { dir = AppDir } | Acc].

delete_dep(Config, D) ->
    case filelib:is_dir(D#dep.dir) of
        true ->
            ok = case get_spil_shared_deps_dir(Config, D) of
                {true, SharedDepDir} ->
                    ?INFO("Deleting shared dependency: ~s\n", [SharedDepDir]),
                    rebar_file_utils:rm_rf(SharedDepDir);
                {false, _} ->
                    ok
            end,
            ?INFO("Deleting dependency: ~s\n", [D#dep.dir]),
            rebar_file_utils:rm_rf(D#dep.dir);
        false ->
            ok
    end.

require_source_engine(Source) ->
    true = source_engine_avail(Source),
    ok.

is_app_available(Config, App, VsnCheck, Path, _IsRaw = false) ->
    ?DEBUG("is_app_available, looking for App ~p with Path ~p~n", [App, Path]),
    case rebar_app_utils:is_app_dir(Path) of
        {true, AppFile} ->
            case rebar_app_utils:app_name(Config, AppFile) of
                {Config1, App} ->
                    {Config2, Vsn} = rebar_app_utils:app_vsn(Config1, AppFile),
                    ?INFO("Looking for ~s-~s ; found ~s-~s at ~s\n",
                          [App, VsnCheck, App, Vsn, Path]),
                    case rebar_version:check(Vsn, VsnCheck) of
                        true ->
                            {memoize_dependency(Config2, App, VsnCheck),
                                {true, Path}};
                        _ ->
                            ?WARN("~s has version ~p; requested was ~1000p\n",
                                [AppFile, Vsn, VsnCheck]),
                            case can_resolve_dependency(
                                    Config2, App, VsnCheck) of
                                true ->
                                    %% We need to clear the cache of the app_vsn
                                    %% Because in a next round we probably have
                                    %% a new version available in the directory
                                    Config3 = rebar_app_utils:app_vsn_reset(
                                        Config2,
                                        AppFile
                                    ),
                                    {Config3,
                                        {false, resolvable_version_mismatch}};
                                {false, Reason} ->
                                    {Config2,
                                        {false, {version_mismatch,
                                                {AppFile,
                                                    {wanted, VsnCheck},
                                                    {has, Vsn},
                                                    Reason}}}}
                            end
                    end;
                {Config1, OtherApp} ->
                    ?WARN("~s has application id ~p; expected ~p\n",
                          [AppFile, OtherApp, App]),
                    {Config1,
                     {false, {name_mismatch,
                              {AppFile, {expected, App}, {has, OtherApp}}}}}
            end;
        false ->
            ?WARN("Expected ~s to be an app dir (containing ebin/*.app), "
                  "but no .app found.\n", [Path]),
            {Config, {false, {missing_app_file, Path}}}
    end;

is_app_available(Config, App, _VsnRegex, Path, _IsRaw = true) ->
    ?DEBUG("is_app_available, looking for Raw Depencency ~p with Path ~p~n",
        [App, Path]),
    case filelib:is_dir(Path) of
        true ->
            %% TODO: look for version string in <Path>/VERSION file? Not clear
            %% how to detect git/svn/hg/{cmd, ...} settings that can be passed
            %% to rebar_utils:vcs_vsn/2 to obtain version dynamically
            {Config, {true, Path}};
        false ->
            ?WARN("Expected ~s to be a raw dependency directory, "
                  "but no directory found.\n", [Path]),
            {Config, {false, {missing_raw_dependency_directory, Path}}}
    end.

use_source(Config, Dep) ->
    use_source(Config, Dep, 3, false).

use_source(_Config, Dep, 0, _) ->
    ?ABORT("Failed to acquire source from ~p after 3 tries.\n",
           [Dep#dep.source]);
use_source(Config, Dep, Count, Force) ->
    case Force of
        true ->
            %% When forcing the retrieve, we need to make sure the directory
            %% does not already exist
            case filelib:is_dir(Dep#dep.dir) of
                true ->
                    rebar_file_utils:rm_rf(Dep#dep.dir);
                false ->
                    ok
            end,
            retrieve_source_and_retry(Config, Dep, Count, Force);
        _ ->
            case filelib:is_dir(Dep#dep.dir) of
                true ->

                    %% Already downloaded -- verify the versioning matches the
                    %% regex
                    case is_app_available(Config, Dep#dep.app,
                                          Dep#dep.vsn_regex,
                                          Dep#dep.dir, Dep#dep.is_raw) of
                        {Config1, {false, resolvable_version_mismatch}} ->
                            ?WARN("Dependency dir ~s failed version-check, but able to resolve.\n",
                                   [Dep#dep.dir]),
                            use_source(Config1, Dep, Count, true);
                        {Config1, {true, _}} ->
                            Dir = filename:join(Dep#dep.dir, "ebin"),
                            ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
                            %% Available version matches up -- we're good to go;
                            %% add the app dir to our code path
                            true = code:add_patha(Dir),
                            {Config1, Dep};
                        {Config1, {false, Reason}} ->
                            %% The app that was downloaded doesn't match up (or had
                            %% errors or something).
                            ?WARN("Dependency dir ~s failed application validation "
                                   "with reason:~n~p.Will retry by removing previous deps dir.\n", [Dep#dep.dir, Reason]),
                            rebar_file_utils:rm_rf(Dep#dep.dir),
                            use_source(Config1, Dep, Count-1, true)
                    end;
                false ->
                    retrieve_source_and_retry(Config, Dep, Count, Force)
            end
    end.


retrieve_source_and_retry(Config, Dep, Count, Force) ->
    %% The shared deps dir might already exist, in that case we only
    %% need to symlink. So construct the download dir and check if it
    %% already exists.
    {true, TargetDir} = get_deps_dir(Config, Dep#dep.app),
    _ = case get_spil_shared_deps_dir(Config, Dep) of
        {false, _} ->
            ok;
        {true, SharedTargetDir} ->
            %% If the (possibly versioned) downloads dir already exists, just
            %% skip downloading the source
            case filelib:is_dir(SharedTargetDir) of
                false ->
                    download_dep(Dep, SharedTargetDir);
                true ->
                    case Force of
                        true ->
                            rebar_file_utils:rm_rf(SharedTargetDir),
                            download_dep(Dep, SharedTargetDir);
                        false ->
                            ok
                    end
            end,
            rebar_file_utils:rm_rf(TargetDir),
            setup_deps_dir(Config, SharedTargetDir, TargetDir)
    end,

    Config1 = case rebar_app_utils:is_app_dir(Dep#dep.dir) of
        {true, AppFile} ->
            rebar_app_utils:app_vsn_reset(Config, AppFile);
        _ ->
            ?WARN("Failed to reload .app file for ~p.\n", [Dep#dep.app]),
            Config
    end,

    use_source(Config1, Dep#dep { dir = TargetDir }, Count-1, false).

%% Helper, downloads dependency from source
download_dep(Dep, Destination) ->
    ?CONSOLE("Pulling ~p from ~p\n", [Dep#dep.app, Dep#dep.source]),
    require_source_engine(Dep#dep.source),
    download_source(Destination, Dep#dep.source).

%% Helper creates a versioned download
get_download_dir(BaseAppDir, {branch, "HEAD"}) ->
    BaseAppDir;
get_download_dir(BaseAppDir, {branch, Branch}) ->
    BaseAppDir ++ "-branch-" ++ Branch;
get_download_dir(BaseAppDir, {tag, Tag}) ->
    BaseAppDir ++ "-tag-" ++ Tag;
get_download_dir(BaseAppDir, {rev, Rev}) ->
    BaseAppDir ++ "-rev-" ++ Rev;
get_download_dir(BaseAppDir, _) ->
    BaseAppDir.

%% Parse the version to a uniform format
parse_version({hg, _, Rev}) ->
    {rev, Rev};
parse_version({git, Url}) ->
    parse_version({git, Url, {branch, "HEAD"}});
parse_version({git, Url, ""}) ->
    parse_version({git, Url, {branch, "HEAD"}});
parse_version({git, _, {branch, Branch}}) ->
    {branch, Branch};
parse_version({git, _, {tag, Tag}}) ->
    {tag, Tag};
parse_version({git, _, Rev}) ->
    {rev, Rev};
parse_version({bzr, _, Rev}) ->
    {rev, Rev};
parse_version({svn, _, Rev}) ->
    {rev, Rev};
parse_version(undefined) ->
    undefined.


%% Downloads the source and returns the directory containing the source.
download_source(AppDir, {hg, Url, Rev}) ->
    ok = filelib:ensure_dir(AppDir),
    rebar_utils:sh(?FMT("hg clone -U ~s ~s", [Url, filename:basename(AppDir)]),
                   [{cd, filename:dirname(AppDir)}]),
    rebar_utils:sh(?FMT("hg update ~s", [Rev]), [{cd, AppDir}]);
download_source(AppDir, {git, Url}) ->
    download_source(AppDir, {git, Url, {branch, "HEAD"}});
download_source(AppDir, {git, Url, ""}) ->
    download_source(AppDir, {git, Url, {branch, "HEAD"}});
download_source(AppDir, {git, Url, {branch, Branch}}) ->
    ok = filelib:ensure_dir(AppDir),
    rebar_utils:sh(?FMT("git clone -n ~s ~s", [Url, filename:basename(AppDir)]),
                   [{cd, filename:dirname(AppDir)}]),
    rebar_utils:sh(?FMT("git checkout -q origin/~s", [Branch]), [{cd, AppDir}]);
download_source(AppDir, {git, Url, {tag, Tag}}) ->
    ok = filelib:ensure_dir(AppDir),
    rebar_utils:sh(?FMT("git clone -n ~s ~s", [Url, filename:basename(AppDir)]),
                   [{cd, filename:dirname(AppDir)}]),
    rebar_utils:sh(?FMT("git checkout -q ~s", [Tag]), [{cd, AppDir}]);
download_source(AppDir, {git, Url, Rev}) ->
    ok = filelib:ensure_dir(AppDir),
    rebar_utils:sh(?FMT("git clone -n ~s ~s", [Url, filename:basename(AppDir)]),
                   [{cd, filename:dirname(AppDir)}]),
    rebar_utils:sh(?FMT("git checkout -q ~s", [Rev]), [{cd, AppDir}]);
download_source(AppDir, {bzr, Url, Rev}) ->
    ok = filelib:ensure_dir(AppDir),
    rebar_utils:sh(?FMT("bzr branch -r ~s ~s ~s",
                        [Rev, Url, filename:basename(AppDir)]),
                   [{cd, filename:dirname(AppDir)}]);
download_source(AppDir, {svn, Url, Rev}) ->
    ok = filelib:ensure_dir(AppDir),
    rebar_utils:sh(?FMT("svn checkout -r ~s ~s ~s",
                        [Rev, Url, filename:basename(AppDir)]),
                   [{cd, filename:dirname(AppDir)}]);
download_source(AppDir, {rsync, Url}) ->
    ok = filelib:ensure_dir(AppDir),
    rebar_utils:sh(?FMT("rsync -az --delete ~s/ ~s", [Url, AppDir]), []);
download_source(AppDir, {fossil, Url}) ->
    download_source(AppDir, {fossil, Url, ""});
download_source(AppDir, {fossil, Url, latest}) ->
    download_source(AppDir, {fossil, Url, ""});
download_source(AppDir, {fossil, Url, Version}) ->
    Repository = filename:join(AppDir, filename:basename(AppDir) ++ ".fossil"),
    ok = filelib:ensure_dir(Repository),
    ok = file:set_cwd(AppDir),
    rebar_utils:sh(?FMT("fossil clone ~s ~s", [Url, Repository]),
                   [{cd, AppDir}]),
    rebar_utils:sh(?FMT("fossil open ~s ~s --nested", [Repository, Version]),
                   []).

update_source(Config, Dep) ->
    %% It's possible when updating a source, that a given dep does not have a
    %% VCS directory, such as when a source archive is built of a project, with
    %% all deps already downloaded/included. So, verify that the necessary VCS
    %% directory exists before attempting to do the update.
    {true, AppDir} = get_deps_dir(Config, Dep#dep.app),
    case has_vcs_dir(element(1, Dep#dep.source), AppDir) of
        true ->
            ?CONSOLE("Updating ~p from ~p\n", [Dep#dep.app, Dep#dep.source]),
            require_source_engine(Dep#dep.source),
            update_source1(AppDir, Dep#dep.source),
            Dep;
        false ->
            ?WARN("Skipping update for ~p: "
                  "no VCS directory available!\n", [Dep]),
            Dep
    end.

update_source1(AppDir, {git, Url}) ->
    update_source1(AppDir, {git, Url, {branch, "HEAD"}});
update_source1(AppDir, {git, Url, ""}) ->
    update_source1(AppDir, {git, Url, {branch, "HEAD"}});
update_source1(AppDir, {git, _Url, {branch, Branch}}) ->
    ShOpts = [{cd, AppDir}],
    rebar_utils:sh("git fetch origin", ShOpts),
    rebar_utils:sh(?FMT("git checkout -q origin/~s", [Branch]), ShOpts);
update_source1(AppDir, {git, _Url, {tag, Tag}}) ->
    ShOpts = [{cd, AppDir}],
    rebar_utils:sh("git fetch --tags origin", ShOpts),
    rebar_utils:sh(?FMT("git checkout -q ~s", [Tag]), ShOpts);
update_source1(AppDir, {git, _Url, Refspec}) ->
    ShOpts = [{cd, AppDir}],
    rebar_utils:sh("git fetch origin", ShOpts),
    rebar_utils:sh(?FMT("git checkout -q ~s", [Refspec]), ShOpts);
update_source1(AppDir, {svn, _Url, Rev}) ->
    rebar_utils:sh(?FMT("svn up -r ~s", [Rev]), [{cd, AppDir}]);
update_source1(AppDir, {hg, _Url, Rev}) ->
    rebar_utils:sh(?FMT("hg pull -u -r ~s", [Rev]), [{cd, AppDir}]);
update_source1(AppDir, {bzr, _Url, Rev}) ->
    rebar_utils:sh(?FMT("bzr update -r ~s", [Rev]), [{cd, AppDir}]);
update_source1(AppDir, {rsync, Url}) ->
    rebar_utils:sh(?FMT("rsync -az --delete ~s/ ~s",[Url,AppDir]),[]);
update_source1(AppDir, {fossil, Url}) ->
    update_source1(AppDir, {fossil, Url, ""});
update_source1(AppDir, {fossil, Url, latest}) ->
    update_source1(AppDir, {fossil, Url, ""});
update_source1(AppDir, {fossil, _Url, Version}) ->
    ok = file:set_cwd(AppDir),
    rebar_utils:sh("fossil pull", [{cd, AppDir}]),
    rebar_utils:sh(?FMT("fossil update ~s", [Version]), []).


%% Remember downloaded dependencies
memoize_dependency(Config, App, VsnCheck) ->
    PreviousAppVersionRestrictions = get_value(Config, {dep,App}, []),

    % Used to be: Config = get_value(config, undefined),
    DepsConfig = get_value(Config, config, undefined),

    % Was: Dir = rebar_config:get_dir(Config), (one got from get_value)
    Dir = rebar_config:get_dir(DepsConfig),
    NewAppVersionRestrictions =
    [{Dir, VsnCheck}] ++ PreviousAppVersionRestrictions,
    set_value(Config, {dep,App}, NewAppVersionRestrictions).

%% Check if we can resolve this new dependency
can_resolve_dependency(Config, App, VsnCheck) ->
    AppDepConstraints = get_value(Config, {dep,App}, []),
    VsnConstraints = [ Constraint || {_, Constraint} <- AppDepConstraints],
    Res = check_dependencies(VsnCheck, VsnConstraints, true),
    case Res of
        false ->
            {false, {reason, {cannot_satisfy, AppDepConstraints}}};
        true ->
            true
    end.

check_dependencies(_, _, false) ->
    false;
check_dependencies(_, [], Res) ->
    Res;
check_dependencies(Vsn, [H|T], _) ->
    check_dependencies(Vsn, T, rebar_version:check(Vsn, H)).

get_value(Config, Key, Default) ->
    DepsConfig = rebar_config:get_global(Config, rebar_deps_config, []),
    proplists:get_value(Key, DepsConfig, Default).

set_value(Config, Key, Value) ->
    DepsConfig = rebar_config:get_global(Config, rebar_deps_config, []),
    TempConfig = proplists:delete(Key, DepsConfig),
    NewConfig = [{Key, Value}] ++ TempConfig,
    rebar_config:set_global(Config, rebar_deps_config, NewConfig).

%% ===================================================================
%% Source helper functions
%% ===================================================================

source_engine_avail(Source) ->
    Name = element(1, Source),
    source_engine_avail(Name, Source).

source_engine_avail(Name, Source)
  when Name == hg; Name == git; Name == svn; Name == bzr; Name == rsync;
       Name == fossil ->
    case vcs_client_vsn(Name) >= required_vcs_client_vsn(Name) of
        true ->
            true;
        false ->
            ?ABORT("Rebar requires version ~p or higher of ~s to process ~p\n",
                   [required_vcs_client_vsn(Name), Name, Source])
    end.

vcs_client_vsn(false, _VsnArg, _VsnRegex) ->
    false;
vcs_client_vsn(Path, VsnArg, VsnRegex) ->
    {ok, Info} = rebar_utils:sh(Path ++ VsnArg, [{env, [{"LANG", "C"}]},
                                                 {use_stdout, false}]),
    case re:run(Info, VsnRegex, [{capture, all_but_first, list}]) of
        {match, Match} ->
            list_to_tuple([list_to_integer(S) || S <- Match]);
        _ ->
            false
    end.

required_vcs_client_vsn(hg)     -> {1, 1};
required_vcs_client_vsn(git)    -> {1, 5};
required_vcs_client_vsn(bzr)    -> {2, 0};
required_vcs_client_vsn(svn)    -> {1, 6};
required_vcs_client_vsn(rsync)  -> {2, 0};
required_vcs_client_vsn(fossil) -> {1, 0}.

vcs_client_vsn(hg) ->
    vcs_client_vsn(rebar_utils:find_executable("hg"), " --version",
                   "version (\\d+).(\\d+)");
vcs_client_vsn(git) ->
    vcs_client_vsn(rebar_utils:find_executable("git"), " --version",
                   "git version (\\d+).(\\d+)");
vcs_client_vsn(bzr) ->
    vcs_client_vsn(rebar_utils:find_executable("bzr"), " --version",
                   "Bazaar \\(bzr\\) (\\d+).(\\d+)");
vcs_client_vsn(svn) ->
    vcs_client_vsn(rebar_utils:find_executable("svn"), " --version",
                   "svn, version (\\d+).(\\d+)");
vcs_client_vsn(rsync) ->
    vcs_client_vsn(rebar_utils:find_executable("rsync"), " --version",
                   "rsync  version (\\d+).(\\d+)");
vcs_client_vsn(fossil) ->
    vcs_client_vsn(rebar_utils:find_executable("fossil"), " version",
                   "version (\\d+).(\\d+)").

has_vcs_dir(git, Dir) ->
    filelib:is_dir(filename:join(Dir, ".git"));
has_vcs_dir(hg, Dir) ->
    filelib:is_dir(filename:join(Dir, ".hg"));
has_vcs_dir(bzr, Dir) ->
    filelib:is_dir(filename:join(Dir, ".bzr"));
has_vcs_dir(svn, Dir) ->
    filelib:is_dir(filename:join(Dir, ".svn"))
        orelse filelib:is_dir(filename:join(Dir, "_svn"));
has_vcs_dir(rsync, _) ->
    true;
has_vcs_dir(_, _) ->
    true.

print_source(#dep{app=App, source=Source}) ->
    ?CONSOLE("~s~n", [format_source(App, Source)]).

format_source(App, {git, Url}) ->
    ?FMT("~p BRANCH ~s ~s", [App, "HEAD", Url]);
format_source(App, {git, Url, ""}) ->
    ?FMT("~p BRANCH ~s ~s", [App, "HEAD", Url]);
format_source(App, {git, Url, {branch, Branch}}) ->
    ?FMT("~p BRANCH ~s ~s", [App, Branch, Url]);
format_source(App, {git, Url, {tag, Tag}}) ->
    ?FMT("~p TAG ~s ~s", [App, Tag, Url]);
format_source(App, {_, Url, Rev}) ->
    ?FMT("~p REV ~s ~s", [App, Rev, Url]);
format_source(App, undefined) ->
    ?FMT("~p", [App]).
