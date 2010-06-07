-module(fabric_view_all_docs).

-export([go/4]).
-export([open_doc/3]). % exported for spawn

-include("fabric.hrl").

go(DbName, #view_query_args{keys=nil} = QueryArgs, Callback, Acc0) ->
    Workers = lists:map(fun(#shard{name=Name, node=Node} = Shard) ->
        Ref = rexi:cast(Node, {fabric_rpc, all_docs, [Name, QueryArgs]}),
        Shard#shard{ref = Ref}
    end, partitions:all_parts(DbName)),
    BufferSize = couch_config:get("fabric", "map_buffer_size", "2"),
    #view_query_args{limit = Limit, skip = Skip} = QueryArgs,
    State = #collector{
        query_args = QueryArgs,
        callback = Callback,
        buffer_size = list_to_integer(BufferSize),
        counters = fabric_dict:init(Workers, 0),
        skip = Skip,
        limit = Limit,
        stop_fun = stop_fun(QueryArgs),
        user_acc = Acc0
    },
    try fabric_util:receive_loop(Workers, #shard.ref, fun handle_message/3,
        State, infinity, 5000) of
    {ok, NewState} ->
        {ok, NewState#collector.user_acc};
    Error ->
        Error
    after
        fabric_util:cleanup(Workers)
    end;

go(DbName, QueryArgs, Callback, Acc0) ->
    #view_query_args{
        direction = Dir,
        include_docs = IncludeDocs,
        limit = Limit0,
        skip = Skip0,
        keys = Keys
    } = QueryArgs,
    {_, Ref0} = spawn_monitor(fun() -> exit(fabric:get_doc_count(DbName)) end),
    Monitors0 = [spawn_monitor(?MODULE, open_doc, [DbName, Id, IncludeDocs]) ||
        Id <- Keys],
    Monitors = if Dir=:=fwd -> Monitors0; true -> lists:reverse(Monitors0) end,
    receive {'DOWN', Ref0, _, _, {ok, TotalRows}} ->
        {ok, Acc1} = Callback({total_and_offset, TotalRows, 0}, Acc0),
        {ok, Acc2} = doc_receive_loop(Monitors, Skip0, Limit0, Callback, Acc1),
        Callback(complete, Acc2)
    after 10000 ->
        Callback(timeout, Acc0)
    end.

handle_message({rexi_DOWN, _, _, _}, nil, State) ->
    % TODO see if progress can be made here, possibly by removing all shards
    % from that node and checking is_progress_possible
    {ok, State};

handle_message({rexi_EXIT, _}, Worker, State) ->
    #collector{callback=Callback, counters=Counters0, user_acc=Acc} = State,
    Counters = fabric_dict:erase(Worker, Counters0),
    case fabric_view:is_progress_possible(Counters) of
    true ->
        {ok, State#collector{counters = Counters}};
    false ->
        Callback({error, dead_shards}, Acc),
        {error, dead_shards}
    end;

handle_message({total_and_offset, Tot, Off}, {Worker, From}, State) ->
    #collector{
        callback = Callback,
        counters = Counters0,
        total_rows = Total0,
        offset = Offset0,
        user_acc = AccIn
    } = State,
    case fabric_dict:lookup_element(Worker, Counters0) of
    undefined ->
        % this worker lost the race with other partition copies, terminate
        gen_server:reply(From, stop),
        {ok, State};
    0 ->
        gen_server:reply(From, ok),
        Counters1 = fabric_dict:update_counter(Worker, 1, Counters0),
        Counters2 = fabric_view:remove_overlapping_shards(Worker, Counters1),
        Total = Total0 + Tot,
        Offset = Offset0 + Off,
        case fabric_dict:any(0, Counters2) of
        true ->
            {ok, State#collector{
                counters = Counters2,
                total_rows = Total,
                offset = Offset
            }};
        false ->
            FinalOffset = erlang:min(Total, Offset+State#collector.skip),
            {Go, Acc} = Callback({total_and_offset, Total, FinalOffset}, AccIn),
            {Go, State#collector{
                counters = fabric_dict:decrement_all(Counters2),
                total_rows = Total,
                offset = FinalOffset,
                user_acc = Acc
            }}
        end
    end;

handle_message(#view_row{} = Row, {Worker, From}, State) ->
    #collector{query_args = Args, counters = Counters0, rows = Rows0} = State,
    Dir = Args#view_query_args.direction,
    Rows = merge_row(Dir, Row#view_row{worker=Worker}, Rows0),
    Counters1 = fabric_dict:update_counter(Worker, 1, Counters0),
    State1 = State#collector{rows=Rows, counters=Counters1},
    State2 = fabric_view:maybe_pause_worker(Worker, From, State1),
    fabric_view:maybe_send_row(State2);

handle_message(complete, Worker, State) ->
    Counters = fabric_dict:update_counter(Worker, 1, State#collector.counters),
    fabric_view:maybe_send_row(State#collector{counters = Counters}).


stop_fun(#view_query_args{direction=fwd, end_key=EndKey}) ->
    fun(#view_row{id=Id}) ->
        couch_db_updater:less_docid(EndKey, Id)
    end;
stop_fun(#view_query_args{direction=rev, end_key=EndKey}) ->
    fun(#view_row{id=Id}) ->
        couch_db_updater:less_docid(Id, EndKey)
    end.

merge_row(fwd, Row, Rows) ->
    lists:keymerge(#view_row.id, [Row], Rows);
merge_row(rev, Row, Rows) ->
    lists:rkeymerge(#view_row.id, [Row], Rows).

doc_receive_loop([], _, _, _, Acc) ->
    {ok, Acc};
doc_receive_loop(_, _, 0, _, Acc) ->
    {ok, Acc};
doc_receive_loop([{Pid,Ref}|Rest], Skip, Limit, Callback, Acc) when Skip > 0 ->
    receive {'DOWN', Ref, process, Pid, #view_row{}} ->
        doc_receive_loop(Rest, Skip-1, Limit-1, Callback, Acc)
    after 10000 ->
        timeout
    end;
doc_receive_loop([{Pid,Ref}|Rest], 0, Limit, Callback, AccIn) ->
    receive {'DOWN', Ref, process, Pid, #view_row{} = Row} ->
        case Callback(fabric_view:transform_row(Row), AccIn) of
        {ok, Acc} ->
            doc_receive_loop(Rest, 0, Limit-1, Callback, Acc);
        {stop, Acc} ->
            {ok, Acc}
        end
    after 10000 ->
        timeout
    end.

open_doc(DbName, Id, IncludeDocs) ->
    Row = case fabric:open_doc(DbName, Id, [deleted]) of
    {not_found, missing} ->
        Doc = undefined,
        #view_row{key=Id};
    {ok, #doc{deleted=true, revs=Revs}} ->
        Doc = null,
        {RevPos, [RevId|_]} = Revs,
        Value = {[{rev,couch_doc:rev_to_str({RevPos, RevId})}, {deleted,true}]},
        #view_row{key=Id, id=Id, value=Value};
    {ok, #doc{revs=Revs} = Doc0} ->
        Doc = couch_doc:to_json_obj(Doc0, []),
        {RevPos, [RevId|_]} = Revs,
        Value = {[{rev,couch_doc:rev_to_str({RevPos, RevId})}]},
        #view_row{key=Id, id=Id, value=Value}
    end,
    exit(if IncludeDocs -> Row#view_row{doc=Doc}; true -> Row end).
