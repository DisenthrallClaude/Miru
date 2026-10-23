local last = -1
mp.observe_property("playback-time", "number", function(_, v) if v then last = v end end)
mp.register_event("shutdown", function() io.stderr:write(string.format("E2EPOS=%.2f\n", last)) end)
