-module(dribble_SUITE).

-include("../src/dribble_int.hrl").
-include_lib("common_test/include/ct.hrl").

-compile(export_all).

-define(to_algo(Pipe), {algorithm, {flows, [{a, public, Pipe}]}, {plugin_defs, []}}).

all() -> [ {group, util}, {group, validator}, {group, factory} ].

groups() ->
    [
        {util, [], [
            t_replace,
            t_enum_map,
            t_enum_filter,
            t_enum_foldl,
            t_set_get_path
        ]},
        {validator, [], [
            t_validate_implements,
            t_pre_validate
        ]},
        {factory, [], [
            t_resolve,
            t_to_beam
        ]}
    ].

suite() ->
    [{ct_hooks, [cth_surefire]}, {timetrap, 1000}].

t_replace(_Config) ->
    [1,c,3] = dribble_util:replace(2, c, [1,2,3]). 

t_enum_map(_Config) ->
    [{1,a},{2,b},{3,c}] = dribble_util:enum_map(fun({Ind, X}) -> {Ind, X} end, [a,b,c]).

t_enum_filter(_Config) ->
    [a,c] = dribble_util:enum_filter(fun({Ind, _}) -> Ind =/= 2 end, [a,b,c]).

t_enum_foldl(_Config) ->
    "1a2b3c" = dribble_util:enum_foldl(fun({Ind, X}, Acc) -> ?format("~s~b~p", [Acc, Ind, X]) end, [], [a,b,c]).

t_validate_implements(_Config) ->
    ok = dribble_validator:validate_implements(user_sup, supervisor_bridge),
    {behaviour_not_implemented,_,_} = (catch dribble_validator:validate_implements(?MODULE, blah)).

t_set_get_path(_Config) ->
  List = dribble_util:set_path(["abcd", {aaa}, 123], 111, []),
  List2 = dribble_util:set_path(["abcd", {aaa}, 456], 222, List),
  List3 = dribble_util:set_path(["abcd", ccc], 333, List2),
  [{"abcd",[{{aaa},[{123,111},
                    {456,222}]},
            {ccc,333}]}] = List3,
  111 = dribble_util:get_path(["abcd", {aaa}, 123], List3),
  222 = dribble_util:get_path(["abcd", {aaa}, 456], List3),
  333 = dribble_util:get_path(["abcd", ccc], List3).

t_pre_validate(_Config) ->
    FilterFn = {fn, fun(_,_) -> ok end},
    ok = dribble_validator:pre_validate(?to_algo([{filter, 'f', FilterFn}])),
    ok = dribble_validator:pre_validate(?to_algo([{filter, 'f', FilterFn}, {sink, a}])),
    {not_last_in_pipe,{sink,a}} = (catch dribble_validator:pre_validate(?to_algo([{sink, a}, {filter, 'f', FilterFn}]))),
    ok = dribble_validator:pre_validate(?to_algo([{filter, 'f', FilterFn}, {branch, [a]}])),
    {not_last_in_pipe,{branch,[a]}} = (catch dribble_validator:pre_validate(?to_algo([{branch, [a]}, {filter, 'f', FilterFn}]))),
    Flowless = {algorithm, {flows, []}, {plugin_defs, []}},
    no_public_flows = (catch dribble_validator:pre_validate(Flowless)),
    DanglingBranches = {algorithm, {flows, [{a, public, [{branch, [b]}]}]}, {plugin_defs, []}},
    {dangling_branches,[b]} = (catch dribble_validator:pre_validate(DanglingBranches)),
    InvalidPipe = {algorithm, {flows, [{a, public, [invalid_pipe_elem]}]}, {plugin_defs, []}},
    {unrecognized_pipe_element,invalid_pipe_elem} = (catch dribble_validator:pre_validate(InvalidPipe)),
    InvalidPluginType = {algorithm, {flows, [{a, public, [{plugin,undefined_plugin,'plugin_path'}]}]}, {plugin_defs, []}},
    {undefined_plugin_type,{plugin,undefined_plugin,plugin_path}} = (catch dribble_validator:pre_validate(InvalidPluginType)),
    InvalidPluginPath = {algorithm, {flows, [{a, public, [{plugin,some_plugin,'undefined_plugin_path'}]}]}, {plugin_defs, [{some_plugin,[]}]}},
    {undefined_plugin_path,{plugin,some_plugin,undefined_plugin_path}} = (catch dribble_validator:pre_validate(InvalidPluginPath)),
    DuplicateFlowIds = {algorithm, {flows, [{a, public, []}, {a, internal, []}]}, {plugin_defs, []}},
    {duplicate_ids,[a]} = (catch dribble_validator:pre_validate(DuplicateFlowIds)),
    DuplicateFlowPluginIds = {algorithm, {flows, [{aa, public, [{plugin, p1, aa}]}]}, {plugin_defs, [{p1, [{aa, []}]}]}},
    {duplicate_ids,[aa]} = (catch dribble_validator:pre_validate(DuplicateFlowPluginIds)).

t_resolve(_Config) ->
    IsUptime = ToAlert = IsDowntime = ToAlert = Getter = fun(_) -> dummy_fun end,
    Algo = {algorithm,
        {flows, [                                               %% input endpoints, either public or internal
            {'cep_in', public,
                [{branch, ['check_downtime', 'check_uptime']}]
            },
            {'check_downtime', internal,
                [{filter, 'is_downtime_ap', {fn, IsUptime}},    %% where data.uptime = -1 && data.logical_group = "ap"
                 {transform, 'to_alert',    {fn, ToAlert}},     %% converts to notification payload
                 {branch, ['stabilizer']}]
            },
            {'check_uptime', internal,
                [{filter, 'is_uptime_ap',   {fn, IsDowntime}},  %% where data.uptime = 0 && data.logical_group = "ap"
                 {transform, 'to_alert',    {fn, ToAlert}},     %% converts to notification payload
                 {branch, ['stabilizer']}]
            },
            {'stabilizer', internal, 
                [{plugin, dribble_window, 'stabilizer_win'},     %% auto re-wires 'stabilizer' to fit in the 'stabilizer_win'
                 {sink, 'output_sink'}]                         %% mandatory sink (must be at least 1)
            }
        ]},

        {plugin_defs, [
            %% For windows, split up the parent flow and insert window flow
            {dribble_window, [
                {'stabilizer_win', [
                    {type, eep_window_tumbling},
                    {size, 30000},
                    {group_by, {fn, Getter([device_id])}}
                ]}
            ]}
        ]}
    },
    Resolved = dribble_factory:resolve(Algo),
    ct:log("Resolved algo: ~p", [Resolved]).
    %% FIXME: validate the above!!!

t_to_beam(_Config) ->
    IsEven  = fun(X) -> X rem 2 == 0 end,
    Times10 = fun(X) -> 10 * X end,
    Algo = {algorithm,
        {flows, [                                               %% input endpoints, either public or internal
            {in, public, [{filter, is_5, {fn, IsEven}}, {branch, [pass, multiplied]}]},
            {pass, internal, [{sink, out_pass}]},
            {multiplied, internal, [{transform, times10, {fn, Times10}}, {sink, out_multiplied}]}
        ]},
        {plugin_defs, []}
    },
    Ctx = dribble:new(Algo),
    {[], Ctx2} = dribble:push(Ctx, in, 5),
    {[{out_pass, [4]}, {out_multiplied, [40]}], _Ctx3} = dribble:push(Ctx2, in, 4).
