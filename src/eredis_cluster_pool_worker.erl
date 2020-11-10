-module(eredis_cluster_pool_worker).
-behaviour(gen_server).
-behaviour(poolboy_worker).

%% API.
-export([start_link/1]).
-export([query/2, is_connected/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {conn, host, port, database, password, options}).

-define(RECONNECT_TIME, 100).

is_connected(Pid) ->
    gen_server:call(Pid, is_connected).

start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

init(Args) ->
    Hostname = proplists:get_value(host, Args),
    Port = proplists:get_value(port, Args),
    DataBase = proplists:get_value(database, Args, 0),
    Password = proplists:get_value(password, Args, ""),
    Options = proplists:get_value(options, Args, []),
    process_flag(trap_exit, true),
    Conn = start_connection(Hostname, Port, DataBase, Password),
    {ok, #state{conn = Conn,
                host = Hostname,
                port = Port,
                database = DataBase,
                password = Password,
                options = Options}}.

query(Worker, Commands) ->
    gen_server:call(Worker, {'query', Commands}).

handle_call({'query', _}, _From, #state{conn = undefined} = State) ->
    {reply, {error, no_connection}, State};
handle_call({'query', [[X|_]|_] = Commands}, _From, #state{conn = Conn} = State)
    when is_list(X); is_binary(X) ->
    {reply, eredis:qp(Conn, Commands), State};
handle_call({'query', Command}, _From, #state{conn = Conn} = State) ->
    {reply, eredis:q(Conn, Command), State};
handle_call(is_connected, _From, #state{conn = Conn}= State) ->
    {reply, Conn =/= undefined andalso is_process_alive(Conn), State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(reconnect, #state{host = Hostname,
                              port = Port,
                              database = DataBase,
                              password = Password} = State) ->
    Conn = start_connection(Hostname, Port, DataBase, Password),
    {noreply, State#state{conn = Conn}};

handle_info({'EXIT', Pid, _Reason}, #state{conn = Pid} = State) ->
    erlang:send_after(?RECONNECT_TIME, self(), reconnect),
    {noreply, State#state{conn = undefined}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{conn=undefined}) ->
    ok;
terminate(_Reason, #state{conn=Conn}) ->
    ok = eredis:stop(Conn),
    ok.
% Down
code_change({down, _V}, #state{conn = Conn,
                               host = Host,
                               port = Port,
                               database = DataBase,
                               password = Password}, _Extra) ->
    {ok, {state, Conn, Host, Port, DataBase, Password}};

% Up
code_change(_V, #state{conn = Conn,
                       host = Host,
                       port = Port,
                       database = DataBase,
                       password = Password}, _Extra) ->
    {ok, {state, Conn, Host, Port, DataBase, Password, []}}.% Up to 0.6.2

start_connection(Hostname, Port, DataBase, Password) ->
    case eredis:start_link(Hostname, Port, DataBase, Password, no_reconnect) of
        {ok,Connection} ->
            Connection;
        _ ->
            erlang:send_after(?RECONNECT_TIME, self(), reconnect),
            undefined
    end.