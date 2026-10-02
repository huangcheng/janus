application:ensure_all_started(janus),
io:format("janus_up~n"),
receive
after
    infinity -> ok
end.
