%% @copyright 2015 Hinagiku Soranoba All Rights Reserved.
%%
%% @doc Binary pattern match Based Mustach template engine for Erlang/OTP.
%%
%% Please refer to [the man page](http://mustache.github.io/mustache.5.html) and [the spec](https://github.com/mustache/spec) of mustache as the need arises.<br />
%%
%% Please see [this](../benchmarks/README.md) for a list of features that bbmustache supports.
%%

-module(bbmustache).

%%----------------------------------------------------------------------------------------------------------------------
%% Exported API
%%----------------------------------------------------------------------------------------------------------------------
-export([
         render/2,
         render/3,
         parse_binary/1,
         parse_binary/2,
         parse_file/1,
         parse_file/2,
         compile/2,
         compile/3,
         default_value_serializer/1
        ]).

-export_type([
              template/0,
              data/0,
              recursive_data/0,
              option/0, % deprecated
              compile_option/0,
              parse_option/0,
              render_option/0
             ]).

%%----------------------------------------------------------------------------------------------------------------------
%% Defines & Records & Types
%%----------------------------------------------------------------------------------------------------------------------

-define(PARSE_ERROR,                incorrect_format).
-define(FILE_ERROR,                 file_not_found).
-define(CONTEXT_MISSING_ERROR(Msg), {context_missing, Msg}).

-define(IIF(Cond, TValue, FValue),
        case Cond of true -> TValue; false -> FValue end).

-define(ADD(X, Y), ?IIF(X =:= <<>>, Y, [X | Y])).
-define(START_TAG, <<"{{">>).
-define(STOP_TAG,  <<"}}">>).

-define(RAISE_ON_CONTEXT_MISS_ENABLED(Options),
        proplists:get_bool(raise_on_context_miss, Options)).
-define(RAISE_ON_PARTIAL_MISS_ENABLED(Options),
        proplists:get_bool(raise_on_partial_miss, Options)).

-define(PARSE_OPTIONS, [raise_on_partial_miss]).

-type key()    :: binary().
%% Key MUST be a non-whitespace character sequence NOT containing the current closing delimiter. <br />
%%
%% In addition, `.' have a special meaning. <br />
%% (1) `parent.child' ... find the child in the parent. <br />
%% (2) `.' ... It means this. However, the type of correspond is only `[integer() | float() | binary() | string() | atom()]'. Otherwise, the behavior is undefined.
%%

-type source() :: binary().
%% If you use lamda expressions, the original text is necessary.
%%
%% ```
%% e.g.
%%   template:
%%     {{#lamda}}a{{b}}c{{/lamda}}
%%   parse result:
%%     {'#', <<"lamda">>, [<<"a">>, {'n', <<"b">>}, <<"c">>], <<"a{{b}}c">>}
%% '''
%%
%% NOTE:
%%   Since the binary reference is used internally, it is not a capacitively large waste.
%%   However, the greater the number of tags used, it should use the wasted memory.

-type tag()    :: {n,   [key()]}
                | {'&', [key()]}
                | {'#', [key()], [tag()], source()}
                | {'^', [key()], [tag()]}
                | {'>', key(), Indent :: source()}
                | binary(). % plain text

-record(?MODULE,
        {
          data               :: [tag()],

          partials      = [] :: [{key(), [tag()]} | key()],
          %% The `{key(), [tag()]}` indicates that `key()` already parsed and `[tag()]` is the result of parsing.
          %% The `key()` indicates that the file did not exist.

          options       = [] :: [compile_option()],
          indents       = [] :: [binary()],
          context_stack = [] :: [data()]
        }).

-opaque template() :: #?MODULE{}.
%% @see parse_binary/1
%% @see parse_file/1

-record(state,
        {
          dirname  = <<>>       :: file:filename_all(),
          start    = ?START_TAG :: binary(),
          stop     = ?STOP_TAG  :: binary(),
          partials = []         :: [key()],
          standalone = true     :: boolean()
        }).
-type state() :: #state{}.

-type parse_option() :: raise_on_partial_miss.
%% - raise_on_partial_miss: If the template used in partials does not found, it will throw an exception (error).

-type compile_option() :: {key_type, atom | binary | string}
                       | raise_on_context_miss
                       | {escape_fun, fun((binary()) -> binary())}
                       | {value_serializer, fun((any()) -> iodata())}.
%% - key_type: Specify the type of the key in {@link data/0}. Default value is `string'.
%% - raise_on_context_miss: If key exists in template does not exist in data, it will throw an exception (error).
%% - escape_fun: Specify your own escape function.
%% - value_serializer: specify how terms are converted to iodata when templating.

-type render_option() :: compile_option() | parse_option().
%% @see compile_option/0
%% @see parse_option/0

-type option() :: compile_option().
%% This type has been deprecated since 1.6.0. It will remove in 2.0.0.
%% @see compile_option/0

-type data() :: term().
%% Beginners should consider {@link data/0} as {@link recursive_data/0}.
%% By specifying options, the type are greatly relaxed and equal to `term/0'.
%%
%% @see render/2
%% @see compile/2

-type data_key() :: atom() | binary() | string().
%% You can choose one from these as the type of key in {@link recursive_data/0}.
%% The default is `string/0'.
%% If you want to change this, you need to specify `key_type' in {@link compile_option/0}.

-ifdef(namespaced_types).
-type recursive_data() :: #{data_key() => term()} | [{data_key(), term()}].
-else.
-type recursive_data() :: [{data_key(), term()}].
-endif.
%% It is a part of {@link data/0} that can have child elements.

-type endtag()    :: {endtag, {state(), [key()], LastTagSize :: non_neg_integer(), Rest :: binary(), Result :: [tag()]}}.

%%----------------------------------------------------------------------------------------------------------------------
%% Exported Functions
%%----------------------------------------------------------------------------------------------------------------------

%% @equiv render(Bin, Data, [])
-spec render(binary(), data()) -> binary().
render(Bin, Data) ->
    render(Bin, Data, []).

%% @equiv compile(parse_binary(Bin), Data, Options)
-spec render(binary(), data(), [render_option()]) -> binary().
render(Bin, Data, Options) ->
    {ParseOptions, CompileOptions} = lists:partition(fun(X) -> lists:member(X, ?PARSE_OPTIONS) end, Options),
    compile(parse_binary(Bin, ParseOptions), Data, CompileOptions).

%% @equiv parse_binary(Bin, [])
-spec parse_binary(binary()) -> template().
parse_binary(Bin) when is_binary(Bin) ->
    parse_binary(Bin, []).

%% @doc Create a {@link template/0} from a binary.
-spec parse_binary(binary(), [parse_option()]) -> template().
parse_binary(Bin, Options) ->
    {State, Data} = parse(#state{}, Bin),
    parse_remaining_partials(State, #?MODULE{data = Data}, Options).

%% @equiv parse_file(Filename, [])
-spec parse_file(file:filename_all()) -> template().
parse_file(Filename) ->
    parse_file(Filename, []).

%% @doc Create a {@link template/0} from a file.
-spec parse_file(file:filename_all(), [parse_option()]) -> template().
parse_file(Filename, Options) ->
    State = #state{dirname = filename:dirname(Filename)},
    case file:read_file(Filename) of
        {ok, Bin} ->
            {State1, Data} = parse(State, Bin),
            Template = case to_binary(filename:extension(Filename)) of
                           <<".mustache">> = Ext -> #?MODULE{partials = [{filename:basename(Filename, Ext), Data}], data = Data};
                           _                     -> #?MODULE{data = Data}
                       end,
            parse_remaining_partials(State1, Template, Options);
        _ ->
            error(?FILE_ERROR, [Filename, Options])
    end.

%% @equiv compile(Template, Data, [])
-spec compile(template(), data()) -> binary().
compile(Template, Data) ->
    compile(Template, Data, []).

%% @doc Embed the data in the template.
%%
%% ```
%% 1> Template = bbmustache:parse_binary(<<"{{name}}">>).
%% 2> bbmustache:compile(Template, #{"name" => "Alice"}).
%% <<"Alice">>
%% '''
%% Data support an associative array or a map. <br />
%% All keys MUST be same type.
-spec compile(template(), data(), [compile_option()]) -> binary().
compile(#?MODULE{data = Tags} = T, Data, Options) ->
    Ret = compile_impl(Tags, Data, [], T#?MODULE{options = Options, data = []}),
    iolist_to_binary(lists:reverse(Ret)).

%% @doc Default value serializer for templtated values
-spec default_value_serializer(number() | binary() | string() | atom()) -> iodata().
default_value_serializer(Integer) when is_integer(Integer) ->
    list_to_binary(integer_to_list(Integer));
default_value_serializer(Float) when is_float(Float) ->
    %% NOTE: It is the same behaviour as io_lib:format("~p", [Float]), but it is fast than.
    %%       http://www.cs.indiana.edu/~dyb/pubs/FP-Printing-PLDI96.pdf
    io_lib_format:fwrite_g(Float);
default_value_serializer(Atom) when is_atom(Atom) ->
    list_to_binary(atom_to_list(Atom));
default_value_serializer(X) when is_map(X); is_tuple(X) ->
    error(unsupported_term, [X]);
default_value_serializer(X) ->
    X.

%%----------------------------------------------------------------------------------------------------------------------
%% Internal Function
%%----------------------------------------------------------------------------------------------------------------------

%% @doc {@link compile/2}
%%
%% ATTENTION: The result is a list that is inverted.
-spec compile_impl(Template :: [tag()], data(), Result :: iodata(), template()) -> iodata().
compile_impl([], _, Result, _) ->
    Result;
compile_impl([{n, Keys} | T], Data, Result, State) ->
    ValueSerializer = proplists:get_value(value_serializer, State#?MODULE.options, fun default_value_serializer/1),
    Value = iolist_to_binary(ValueSerializer(get_data_recursive(Keys, Data, <<>>, State))),
    EscapeFun = proplists:get_value(escape_fun, State#?MODULE.options, fun escape/1),
    compile_impl(T, Data, ?ADD(EscapeFun(Value), Result), State);
compile_impl([{'&', Keys} | T], Data, Result, State) ->
    ValueSerializer = proplists:get_value(value_serializer, State#?MODULE.options, fun default_value_serializer/1),
    compile_impl(T, Data, ?ADD(ValueSerializer(get_data_recursive(Keys, Data, <<>>, State)), Result), State);
compile_impl([{'#', Keys, Tags, Source} | T], Data, Result, State) ->
    Value = get_data_recursive(Keys, Data, false, State),
    NestedState = State#?MODULE{context_stack = [Data | State#?MODULE.context_stack]},
    case is_recursive_data(Value) of
      true ->
            compile_impl(T, Data, compile_impl(Tags, Value, Result, NestedState), State);
      _ when is_list(Value) ->
            compile_impl(T, Data, lists:foldl(fun(X, Acc) -> compile_impl(Tags, X, Acc, NestedState) end,
                                             Result, Value), State);
      _ when Value =:= false ->
            compile_impl(T, Data, Result, State);
      _ when is_function(Value, 2) ->
            Ret = Value(Source, fun(Text) -> render(Text, Data, State#?MODULE.options) end),
            compile_impl(T, Data, ?ADD(Ret, Result), State);
      _ ->
            compile_impl(T, Data, compile_impl(Tags, Data, Result, State), State)
    end;
compile_impl([{'^', Keys, Tags} | T], Data, Result, State) ->
    Value = get_data_recursive(Keys, Data, false, State),
    case Value =:= [] orelse Value =:= false of
        true  -> compile_impl(T, Data, compile_impl(Tags, Data, Result, State), State);
        false -> compile_impl(T, Data, Result, State)
    end;
compile_impl([{'>', Key, Indent} | T], Data, Result0, #?MODULE{partials = Partials} = State) ->
    case proplists:get_value(Key, Partials) of
        undefined ->
            case ?RAISE_ON_CONTEXT_MISS_ENABLED(State#?MODULE.options) of
                true  -> error(?CONTEXT_MISSING_ERROR({?FILE_ERROR, Key}));
                false -> compile_impl(T, Data, Result0, State)
            end;
        PartialT  ->
            Indents = State#?MODULE.indents ++ [Indent],
            Result1 = compile_impl(PartialT, Data, [Indent | Result0], State#?MODULE{indents = Indents}),
            compile_impl(T, Data, Result1, State)
    end;
compile_impl([B1 | [_|_] = T], Data, Result, #?MODULE{indents = Indents} = State) when Indents =/= [] ->
    %% NOTE: indent of partials
    case byte_size(B1) > 0 andalso binary:last(B1) of
        $\n -> compile_impl(T, Data, [Indents, B1 | Result], State);
        _   -> compile_impl(T, Data, [B1 | Result], State)
    end;
compile_impl([Bin | T], Data, Result, State) ->
    compile_impl(T, Data, [Bin | Result], State).

%% @doc Parse remaining partials in State. It returns {@link template/0}.
-spec parse_remaining_partials(state(), template(), [parse_option()]) -> template().
parse_remaining_partials(#state{partials = []}, Template = #?MODULE{}, _Options) ->
    Template;
parse_remaining_partials(State = #state{partials = [P | PartialKeys]}, Template = #?MODULE{partials = Partials}, Options) ->
    case proplists:is_defined(P, Partials) of
        true  -> parse_remaining_partials(State#state{partials = PartialKeys}, Template, Options);
        false ->
            Filename0 = <<P/binary, ".mustache">>,
            Dirname   = State#state.dirname,
            Filename  = ?IIF(Dirname =:= <<>>, Filename0, filename:join([Dirname, Filename0])),
            case file:read_file(Filename) of
                {ok, Input} ->
                    {State1, Data} = parse(State, Input),
                    parse_remaining_partials(State1, Template#?MODULE{partials = [{P, Data} | Partials]}, Options);
                {error, Reason} ->
                    case ?RAISE_ON_PARTIAL_MISS_ENABLED(Options) of
                        true  -> error({?FILE_ERROR, P, Reason});
                        false -> parse_remaining_partials(State#state{partials = PartialKeys},
                                                          Template#?MODULE{partials = [P | Partials]}, Options)
                    end
            end
    end.

%% @doc Analyze the syntax of the mustache.
-spec parse(state(), binary()) -> {#state{}, [tag()]}.
parse(State0, Bin) ->
    case parse1(State0, Bin, []) of
        {endtag, {_, Keys, _, _, _}} ->
            error({?PARSE_ERROR, {section_is_incorrect, binary_join(Keys, <<".">>)}});
        {#state{partials = Partials} = State, Tags} ->
            {State#state{partials = lists:usort(Partials), start = ?START_TAG, stop = ?STOP_TAG},
             lists:reverse(Tags)}
    end.

%% @doc Part of the `parse/1'
%%
%% ATTENTION: The result is a list that is inverted.
-spec parse1(state(), Input :: binary(), Result :: [tag()]) -> {state(), [tag()]} | endtag().
parse1(#state{start = Start} = State, Bin, Result) ->
    case binary:match(Bin, [Start, <<"\n">>]) of
        nomatch -> {State, ?ADD(Bin, Result)};
        {S, L}  ->
            Pos = S + L,
            B2  = binary:part(Bin, Pos, byte_size(Bin) - Pos),
            case binary:at(Bin, S) of
                $\n -> parse1(State#state{standalone = true}, B2, ?ADD(binary:part(Bin, 0, Pos), Result)); % \n
                _   -> parse2(State, split_tag(State, Bin), Result)
            end
    end.

%% @doc Part of the `parse/1'
%%
%% ATTENTION: The result is a list that is inverted.
-spec parse2(state(), iolist(), Result :: [tag()]) -> {state(), [tag()]} | endtag().
parse2(State, [B1, B2, B3], Result) ->
    case remove_space_from_head(B2) of
        <<T, Tag/binary>> when T =:= $&; T =:= ${ ->
            parse1(State#state{standalone = false}, B3, [{'&', keys(Tag)} | ?ADD(B1, Result)]);
        <<T, Tag/binary>> when T =:= $#; T =:= $^ ->
            parse_loop(State, ?IIF(T =:= $#, '#', '^'), keys(Tag), B3, [B1 | Result]);
        <<"=", Tag0/binary>> ->
            Tag1 = remove_space_from_tail(Tag0),
            Size = byte_size(Tag1) - 1,
            case Size >= 0 andalso Tag1 of
                <<Tag2:Size/binary, "=">> -> parse_delimiter(State, Tag2, B3, [B1 | Result]);
                _                         -> error({?PARSE_ERROR, {unsupported_tag, <<"=", Tag0/binary>>}})
            end;
        <<"!", _/binary>> ->
            parse3(State, B3, [B1 | Result]);
        <<"/", Tag/binary>> ->
            EndTagSize = byte_size(B2) + byte_size(State#state.start) + byte_size(State#state.stop),
            {endtag, {State, keys(Tag), EndTagSize, B3, [B1 | Result]}};
        <<">", Tag/binary>> ->
            parse_jump(State, filename_key(Tag), B3, [B1 | Result]);
        Tag ->
            parse1(State#state{standalone = false}, B3, [{n, keys(Tag)} | ?ADD(B1, Result)])
    end;
parse2(_, _, _) ->
    error({?PARSE_ERROR, unclosed_tag}).

%% @doc Part of the `parse/1'
%%
%% it is end processing of tag that need to be considered the standalone.
-spec parse3(#state{}, binary(), [tag()]) -> {state(), [tag()]} | endtag().
parse3(State0, Post0, [Tag | Result0]) when is_tuple(Tag) ->
    {State1, _, Post1, Result1} = standalone(State0, Post0, Result0),
    parse1(State1, Post1, [Tag | Result1]);
parse3(State0, Post0, Result0) ->
    {State1, _, Post1, Result1} = standalone(State0, Post0, Result0),
    parse1(State1, Post1, Result1).

%% @doc Loop processing part of the `parse/1'
%%
%% `{{# Tag}}' or `{{^ Tag}}' corresponds to this.
-spec parse_loop(state(), '#' | '^', [key()], Input :: binary(), Result :: [tag()]) -> {state(), [tag()]} | endtag().
parse_loop(State0, Mark, Keys, Input0, Result0) ->
    {State1, _, Input1, Result1} = standalone(State0, Input0, Result0),
    case parse1(State1, Input1, []) of
        {endtag, {State2, Keys, LastTagSize, Rest0, LoopResult0}} ->
            {State3, _, Rest1, LoopResult1} = standalone(State2, Rest0, LoopResult0),
            case Mark of
                '#' -> Source = binary:part(Input1, 0, byte_size(Input1) - byte_size(Rest1) - LastTagSize),
                       parse1(State3, Rest1, [{'#', Keys, lists:reverse(LoopResult1), Source} | Result1]);
                '^' -> parse1(State3, Rest1, [{'^', Keys, lists:reverse(LoopResult1)} | Result1])
            end;
        {endtag, {_, OtherKeys, _, _, _}} ->
            error({?PARSE_ERROR, {section_is_incorrect, binary_join(OtherKeys, <<".">>)}});
        _ ->
            error({?PARSE_ERROR, {section_end_tag_not_found, <<"/", (binary_join(Keys, <<".">>))/binary>>}})
    end.

%% @doc Endtag part of the `parse/1'
-spec parse_jump(state(), Tag :: binary(), NextBin :: binary(), Result :: [tag()]) -> {state(), [tag()]} | endtag().
parse_jump(State0, Tag, NextBin0, Result0) ->
    {State1, Indent, NextBin1, Result1} = standalone(State0, NextBin0, Result0),
    State2 = State1#state{partials = [Tag | State1#state.partials]},
    parse1(State2, NextBin1, [{'>', Tag, Indent} | Result1]).

%% @doc Update delimiter part of the `parse/1'
%%
%% ParseDelimiterBin :: e.g. `{{=%% %%=}}' -> `%% %%'
-spec parse_delimiter(state(), ParseDelimiterBin :: binary(), NextBin :: binary(), Result :: [tag()]) -> {state(), [tag()]} | endtag().
parse_delimiter(State0, ParseDelimiterBin, NextBin, Result) ->
    case binary:match(ParseDelimiterBin, <<"=">>) of
        nomatch ->
            case [X || X <- binary:split(ParseDelimiterBin, <<" ">>, [global]), X =/= <<>>] of
                [Start, Stop] -> parse3(State0#state{start = Start, stop = Stop}, NextBin, Result);
                _             -> error({?PARSE_ERROR, delimiters_may_not_contain_whitespaces})
            end;
        _ ->
            error({?PARSE_ERROR, delimiters_may_not_contain_equals})
    end.

%% @doc Split by the tag, it returns a list of the split binary.
%%
%% e.g.
%% ```
%% 1> split_tag(State, <<"...{{hoge}}...">>).
%% [<<"...">>, <<"hoge">>, <<"...">>]
%%
%% 2> split_tag(State, <<"...{{hoge ...">>).
%% [<<"...">>, <<"hoge ...">>]
%%
%% 3> split_tag(State, <<"...">>)
%% [<<"...">>]
%% '''
-spec split_tag(state(), binary()) -> [binary(), ...].
split_tag(#state{start = StartDelimiter, stop = StopDelimiter}, Bin) ->
    case binary:match(Bin, StartDelimiter) of
        nomatch ->
            [Bin];
        {StartPos, StartDelimiterLen} ->
            PosLimit = byte_size(Bin) - StartDelimiterLen,
            ShiftNum = while({true, StartPos + 1},
                             fun(Pos) ->
                                     ?IIF(Pos =< PosLimit
                                          andalso binary:part(Bin, Pos, StartDelimiterLen) =:= StartDelimiter,
                                          {true, Pos + 1}, {false, Pos})
                             end) - StartPos - 1,
            {PreTag, X} = split_binary(Bin, StartPos + ShiftNum),
            Tag0        = part(X, StartDelimiterLen, 0),
            case binary:split(Tag0, StopDelimiter) of
                [_]          -> [PreTag, Tag0]; % not found.
                [Tag, Rest]  ->
                    IncludeStartDelimiterTag = binary:part(X, 0, byte_size(Tag) + StartDelimiterLen),
                    E = ?IIF(repeatedly_binary(StopDelimiter, $}),
                             ?IIF(byte_size(Rest) > 0 andalso binary:first(Rest) =:= $}, 1, 0),
                             ?IIF(byte_size(Tag) > 0 andalso binary:last(Tag) =:= $}, -1, 0)),
                    S = ?IIF(repeatedly_binary(StartDelimiter, ${),
                             ?IIF(ShiftNum > 0, -1, 0),
                             ?IIF(byte_size(Tag) > 0 andalso binary:first(Tag) =:= ${, 1, 0)),
                    case E =:= 0 orelse S =:= 0 of
                        true ->  % {{ ... }}
                            [PreTag, Tag, Rest];
                        false -> % {{{ ... }}}
                            [part(PreTag, 0, min(0, S)),
                             part(IncludeStartDelimiterTag, max(0, S) + StartDelimiterLen - 1, min(0, E)),
                             part(Rest, max(0, E), 0)]
                    end
            end
    end.

%% @doc if it is standalone line, remove spaces from edge.
-spec standalone(#state{}, binary(), [tag()]) -> {#state{}, StashPre :: binary(), Post :: binary(), [tag()]}.
standalone(#state{standalone = false} = State, Post, [Pre | Result]) ->
    {State, <<>>, Post, ?ADD(Pre, Result)};
standalone(#state{standalone = false} = State, Post, Result) ->
    {State, <<>>, Post, Result};
standalone(State, Post0, Result0) ->
    {Pre, Result1} = case Result0 =/= [] andalso hd(Result0) of
                         Pre0 when is_binary(Pre0) -> {Pre0, tl(Result0)};
                         _                         -> {<<>>, Result0}
                     end,
    case remove_indent_from_head(Pre) =:= <<>> andalso remove_indent_from_head(Post0) of
        <<"\r\n", Post1/binary>> ->
            {State, Pre, Post1, Result1};
        <<"\n", Post1/binary>> ->
            {State, Pre, Post1, Result1};
        <<>> ->
            {State, Pre, <<>>, Result1};
        _ ->
            {State#state{standalone = false}, <<>>, Post0, ?ADD(Pre, Result1)}
    end.

%% @doc If the binary is repeatedly the character, return true. Otherwise, return false.
-spec repeatedly_binary(binary(), byte()) -> boolean().
repeatedly_binary(<<X, Rest/binary>>, X) ->
    repeatedly_binary(Rest, X);
repeatedly_binary(<<>>, _) ->
    true;
repeatedly_binary(_, _) ->
    false.

%% @doc During the first element of the tuple is true, to perform the function repeatedly.
-spec while({boolean(), term()}, fun((term()) -> {boolean(), term()})) -> term().
while({true, Value}, Fun) ->
    while(Fun(Value), Fun);
while({false, Value}, _Fun) ->
    Value.

%% @equiv binary:part(X, Start, byte_size(X) - Start + End)
-spec part(binary(), non_neg_integer(), 0 | neg_integer()) -> binary().
part(X, Start, End) when End =< 0 ->
    binary:part(X, Start, byte_size(X) - Start + End).

%% @doc binary to keys
-spec keys(binary()) -> [key()].
keys(Bin0) ->
    Bin1 = << <<X:8>> || <<X:8>> <= Bin0, X =/= $  >>,
    case Bin1 =:= <<>> orelse Bin1 =:= <<".">> of
        true  -> [Bin1];
        false -> [X || X <- binary:split(Bin1, <<".">>, [global]), X =/= <<>>]
    end.

%% @doc binary to filename key
-spec filename_key(binary()) -> key().
filename_key(Bin) ->
    remove_space_from_tail(remove_space_from_head(Bin)).

%% @doc Function for binary like the `string:join/2'.
-spec binary_join(BinaryList :: [binary()], Separator :: binary()) -> binary().
binary_join([], _) ->
    <<>>;
binary_join(Bins, Sep) ->
    [Hd | Tl] = [ [Sep, B] || B <- Bins ],
    iolist_to_binary([tl(Hd) | Tl]).

%% @doc Remove the space from the head.
-spec remove_space_from_head(binary()) -> binary().
remove_space_from_head(<<" ", Rest/binary>>) -> remove_space_from_head(Rest);
remove_space_from_head(Bin)                  -> Bin.

%% @doc Remove the indent from the head.
-spec remove_indent_from_head(binary()) -> binary().
remove_indent_from_head(<<X:8, Rest/binary>>) when X =:= $\t; X =:= $  ->
    remove_indent_from_head(Rest);
remove_indent_from_head(Bin) ->
    Bin.

%% @doc Remove the space from the tail.
-spec remove_space_from_tail(binary()) -> binary().
remove_space_from_tail(<<>>) -> <<>>;
remove_space_from_tail(Bin) ->
    PosList = binary:matches(Bin, <<" ">>),
    LastPos = remove_space_from_tail_impl(lists:reverse(PosList), byte_size(Bin)),
    binary:part(Bin, 0, LastPos).

%% @see remove_space_from_tail/1
-spec remove_space_from_tail_impl([{non_neg_integer(), pos_integer()}], non_neg_integer()) -> non_neg_integer().
remove_space_from_tail_impl([{X, Y} | T], Size) when Size =:= X + Y ->
    remove_space_from_tail_impl(T, X);
remove_space_from_tail_impl(_, Size) ->
    Size.

%% @doc string or binary to binary
-spec to_binary(binary() | [byte()]) -> binary().
to_binary(Bin) when is_binary(Bin) ->
    Bin;
to_binary(Bytes) when is_list(Bytes) ->
    list_to_binary(Bytes).

%% @doc HTML Escape
-spec escape(binary()) -> binary().
escape(Bin) ->
    << <<(escape_char(X))/binary>> || <<X:8>> <= Bin >>.

%% @doc escape a character if needed.
-spec escape_char(byte()) -> <<_:8, _:_*8>>.
escape_char($<) -> <<"&lt;">>;
escape_char($>) -> <<"&gt;">>;
escape_char($&) -> <<"&amp;">>;
escape_char($") -> <<"&quot;">>;
escape_char(C)  -> <<C:8>>.

%% @doc convert to {@link data_key/0} from binary.
-spec convert_keytype(key(), template()) -> data_key().
convert_keytype(KeyBin, #?MODULE{options = Options}) ->
    case proplists:get_value(key_type, Options, string) of
        atom ->
            try binary_to_existing_atom(KeyBin, utf8) of
                Atom -> Atom
            catch
                _:_ -> <<" ">> % It is not always present in data/0
            end;
        string -> binary_to_list(KeyBin);
        binary -> KeyBin
    end.

%% @doc fetch the value of the specified `Keys' from {@link data/0}
%%
%% - If `Keys' is `[<<".">>]', it returns `Data'.
%% - If raise_on_context_miss enabled, it raise an exception when missing `Keys'. Otherwise, it returns `Default'.
-spec get_data_recursive([key()], data(), Default :: term(), template()) -> term().
get_data_recursive(Keys, Data, Default, Template) ->
    case get_data_recursive_impl(Keys, Data, Template) of
        {ok, Term} -> Term;
        error      ->
            case ?RAISE_ON_CONTEXT_MISS_ENABLED(Template#?MODULE.options) of
                true  -> error(?CONTEXT_MISSING_ERROR({key, binary_join(Keys, <<".">>)}));
                false -> Default
            end
    end.

%% @see get_data_recursive/4
-spec get_data_recursive_impl([key()], data(), template()) -> {ok, term()} | error.
get_data_recursive_impl([], Data, _) ->
    {ok, Data};
get_data_recursive_impl([<<".">>], Data, _) ->
    {ok, Data};
get_data_recursive_impl([Key | RestKey] = Keys, Data, #?MODULE{context_stack = Stack} = State) ->
    case is_list(Data) andalso find_index_data_from_lists(Key, Data) of
        {ok, ChildData} -> {ok, ChildData};
        _               ->
            case is_recursive_data(Data) andalso find_data(convert_keytype(Key, State), Data) of
                {ok, ChildData} ->
                    get_data_recursive_impl(RestKey, ChildData, State#?MODULE{context_stack = []});
                _ when Stack =:= [] ->
                    error;
                _ ->
                    get_data_recursive_impl(Keys, hd(Stack), State#?MODULE{context_stack = tl(Stack)})
            end
     end.

%% @doc find the value of the specified key from {@link recursive_data/0}
-spec find_data(data_key(), recursive_data() | term()) -> {ok, Value :: term()} | error.
-ifdef(namespaced_types).
find_data(Key, Map) when is_map(Map) ->
    maps:find(Key, Map);
find_data(Key, AssocList) when is_list(AssocList) ->
    case data_key_to_integer(Key) of
        {ok, Index} ->
            try lists:nth(Index, AssocList) of 
                Value -> {ok, Value}
            catch
                _ -> {ok, <<>>}
            end;

        _ ->
            %% If key is not integer parse as Associated List
            case proplists:lookup(Key, AssocList) of
                none   -> error;
                {_, V} -> {ok, V}
            end
    end;
find_data(_, _) ->
    error.
-else.
find_data(Key, AssocList) ->
    case data_key_to_integer(Key) of
        {ok, Index} ->
            try lists:nth(Index, AssocList) of 
                Value -> {ok, Value}
            catch
                _ -> {ok, <<>>}
            end;

        _ ->
            case proplists:lookup(Key, AssocList) of
                none   -> error;
                {_, V} -> {ok, V}
            end
    end;
find_data(_, _) ->
    error.
-endif.

%% @doc When the value is {@link recursive_data/0}, it returns true. Otherwise it returns false.
-spec is_recursive_data(recursive_data() | term()) -> boolean().
-ifdef(namespaced_types).
is_recursive_data([Tuple | _]) when is_tuple(Tuple) -> true;
is_recursive_data(V) when is_map(V)                 -> true;
is_recursive_data(_)                                -> false.
-else.
is_recursive_data([Tuple | _]) when is_tuple(Tuple) -> true;
is_recursive_data(_)                                -> false.
-endif.

%% @doc When the value can convert integer, it returns the integer. Otherwise it returns error.
-spec safe_binary_to_integer(binary()) -> integer() | error.
safe_binary_to_integer(Bin) ->
    try
        binary_to_integer(Bin)
    catch _:_ ->
        error
    end.

-spec find_index_data_from_lists(binary(), list()) -> {ok, term()} | error.
find_index_data_from_lists(IndexBin, List) ->
    case safe_binary_to_integer(IndexBin) of
        Index when is_integer(Index), Index >= 0 ->
            try
                {ok, lists:nth(Index + 1, List)}
            catch _:_ ->
                error
            end;
        _ ->
            error
    end.

-spec can_access_as_list(data_key(), recursive_data() | term()) -> boolean().
can_access_as_list(Key, Value) when is_list(Value) ->
    case data_key_to_integer(Key) of
        {ok, _} -> true;
        _ -> false
    end;
can_access_as_list(_, _) -> false.

-spec data_key_to_integer(data_key()) -> {ok, integer()} | error.
data_key_to_integer(Key) when is_binary(Key) ->
    case string:to_integer(Key) of
        {Index, <<>>} -> {ok, Index};
        _ -> error
    end;
data_key_to_integer(Key) when is_list(Key) ->
    case string:to_integer(Key) of
        {Index, []} -> {ok, Index};
        _ -> error
    end;
data_key_to_integer(Key) when is_atom(Key) ->
    data_key_to_integer(atom_to_list(Key));
data_key_to_integer(_) ->
    error.
