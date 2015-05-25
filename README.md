*Dribble* - embedded CEP engine
===============================

Build status (master): [![Build Status](https://travis-ci.org/konrads/dribble.svg?branch=master)](https://travis-ci.org/konrads/dribble)

A CEP library with an OTP application layer. Based on:
* [beam-erl v0.2.0](https://github.com/darach/beam-erl/tree/v0.2.0/src)
* [eep-erl](https://github.com/darach/eep-erl)

As a libary, *dribble* facilitates construction of algorithms via DSL. An algorithm is implemented by a single beam flow, and consisting of beam filters|transforms|branches and more complex constructs - `boxes`. A `box` provides a runtime behaviour that manipulates stream events and `box` context (partition of beam_flow context), wrapped up in a beam sub-flow. Common `box` implementations such as eep `windows` are promoted to first class *dribble* citizens by implementing a plugin behaviour that defines custom DSL and auto wire-up functionality.

As an OTP application, *dribble* provides a thin process layer to manage algorithms, expose public endpoints, drive eep `window` clock ticks. Further functionality - to be considered...

Sample usage
------------

First, create some helper functions:

``` erlang
% helpers
Eq = fun(Path, ExpVal) -> fun(Data) -> kvlists:get_path(Path, Data) =:= ExpVal end end.
And = fun(Predicates) -> fun(Data) -> lists:usort([ P(Data) || P <- Predicates]) == [true] end end.
Getter = fun(Path) -> fun(Event) -> kvlists:get_path(Path, Event) end end.
Get = fun kvlists:get_path/2.

% filters and transforms
IsUptime = And([Eq([data, uptime], -1), Eq([data, logical_group], "ap")]).
IsDowtime = And([Eq([data, uptime], 0), Eq([data, logical_group], "ap")]).
ToAlert = fun(Data) ->
    [{alert_type,        "APDisconnected"},
     {alert_title,       "AP offline"},
     {alert_description, "An AP device has gone offline"},
     {organization_id,   Get([organization_id], Data)},
     {device_id,         Get([device_id], Data)},
     {device_ip,         Get([device_ip], Data)},
     {device_host,       Get([device_host], Data)}
    ]
end.
```

Next, configure an algorithm in *dribble* DSL. Note, quoted 'atoms' represent user defined labels, unquoted atoms - DSL syntax.

``` erlang
Algo = {algorithm, [
    {flows, [                                               %% input endpoints, either public or internal
        {'cep_in', public,
            [{branch, ['check_downtime', 'check_uptime']}]
        },
        {'check_downtime', internal,
            [{filter, 'is_downtime_ap', {fn, IsUptime}},    %% where data.uptime = -1 && data.logical_group = "ap"
             {transform, 'to_alert',    {fn, ToAlert}},     %% converts to notification payload
             {box, 'populate_parent', data_in}]
        },
        {'check_downtime-cont', internal,                   %% continuation flow for 'populate_parent'
            [{branch, ['stabilizer']}]
        },
        {'check_uptime', internal,
            [{filter, 'is_uptime_ap',   {fn, IsDowntime}},  %% where data.uptime = 0 && data.logical_group = "ap"
             {transform, 'to_alert',    {fn, ToAlert}},     %% converts to notification payload
             {branch, ['stabilizer']}]
        },
        {'stabilizer', internal, 
            [{window, 'stabilizer_win'},                    %% auto re-wires 'stabilizer' to fit in the 'stabilizer_win'
             {sink, 'output_sink'}]                         %% mandatory sink (must be at least 1)
        }
    ]},

    {plugin_defs, [
        %% define boxes with their implementation module, in/out ports, initial config
        {box, [
            {'populate_parent', [
                {impl, populate_parent_op},
                {in,   [data_in]},                              %% input port
                {out,  [{data_out, 'check_downtime-cont'}]},    %% output port pointing to 'check_downtime-cont' pipe
                {with, [{evict_every, 3600000}]}
            ]}
        ]},

        %% For windows, split up the parent flow and insert window flow
        {window, [
            {'stabilizer_win', [
                {type, eep_window_tumbling},
                {size, 30000},
                {group_by, {fn, Getter([device_id])}}
            ]}
        ]}
    ]}
]}.
```

To run as a process-less library, push through both events and clock ticks:
``` erlang
DribbleState = dribble:new(AlgoDSL),
{ok, Res2, DribbleState2} = dribble:push(DribbleState, Event),
{ok, Res3, AuditLog3, DribbleState3} = dribble:push(DribbleState2, Event2, true),  % with audit
{ok, Res4, DribbleState4} = dribble:tick(DribbleState3, stabilizer_win).
```

As OTP app, clock ticks are generated by the application:
``` erlang
application:load(dribble),
application:set_env(dribble, tick_freq, 100),                  % tick every 100 ms
application:start(dribble),
{ok, Pid} = dribble:start_link(my_algo, AlgoDSL),
% to get existing algo
{ok, Pid} = dribble:get_instance(my_algo),
{ok, Res2} = dribble:push(Pid, Event1),
{ok, Res3, AuditLog3} = dribble:push(Pid, Event2, true).       % with audit
```

Where:
* Res1/2/3/4 - map of results, if any any generated, eg. [{output_sink, Val}], or []
* AuditLog3 - audit log on filters, transformers, branches, boxes, windows


Implementation
--------------

Pipes, branches, transforms and filters have a 1-to-1 mapping with beam constructs.

Generic `boxes` require additional internal flows:
```
    {'populate_parent-data_in',  internal, [{transform, 'enqueue', {fn, BoxEnqueue}},
                                            {branch, ['populate_parent-data_out']}]},
    {'populate_parent-data_out', internal, [{filter, 'is_data_out', {fn, PortMatches(data_out)}},
                                            {branch, ['check_downtime-cont']}]},
```

`windows` require new flows and re-wiring of 'stabilizer' flow:
```
    {'stabilizer',          internal, [{branch, ['stabilizer_win-in']}]},
    {'stabilizer-cont',     internal, [{sink, output_sink}]},
    {'stabilizer_win-in1',  internal, [{transform, 'stabilizer_win-enqueue', {fn, WindowEqueue}},
                                       {filter, {fn IsEmpty}},                                     % drop if no enqueue output
                                       {branch, ['stabilizer-cont']}                               % follow up the remainder of 'stabilizer'
                                      ]},
    {'stabilizer_win-tick1', public,  [{transform, 'stabilizer_win-tick', {fn, WindowTick}},
                                       {filter, {fn IsEmpty}},                                     % drop if no tick output
                                       {branch, ['stabilizer-cont']}                               % follow up the remainder of 'stabilizer'
                                      ]},
```

Algorithm construction requires multiple passes, eg.
* determine used plugins
* generate all beam pipes, for both flows and `boxes`(/`windows`)
* fill in in all pipes, generic or `box`
* validate no cyclic graphs, no dead ends

`box`(/`window`) construction is delegated to dribble_plugin_box(/dribble_plugin_window). Flows, which drive the entire construction, get a preferential treatment and hence differ from plugins.


TBD
---

Rename `boxes` to represent pluggable units of work...

Clock ticks in OTP app - should they be part of algorithm, driven externally?

System events - should be done on the OTP app layer. Processes at that level have access to the flow (for eg. `tick`) and beam context (for eg. hinted handoff)

beam_flow:minimize/optimize/flatten() - denormalize 1-to-1 branches into single pipes, for speed
