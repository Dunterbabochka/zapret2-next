-- Offline regression test loaded by winws2 with interception disabled.
assert(type(next_hostfakesplit) == "function")
local names = {
    "direction_cutoff_opposite", "instance_cutoff_shim", "direction_check",
    "payload_check", "replay_first", "replay_drop", "replay_drop_set",
    "resolve_range", "genhost", "rawsend_opts_base", "rawsend_opts",
    "reconstruct_opts", "rawsend_payload_segmented"
}
local saved = {}
for _, name in ipairs(names) do saved[name] = _G[name] end
local sent, fail_at, missing_host, cutoff
direction_cutoff_opposite = function() end
instance_cutoff_shim = function() cutoff = true end
direction_check = function(d) return not d.incoming end
payload_check = function(d) return not d.unknown end
replay_first = function(d) return not d.replayed end
replay_drop = function(d) return d.dropped end
replay_drop_set = function(d) d.dropped = true end
resolve_range = function() if not missing_host then return {7, 14} end end
genhost = function(length, host) assert(length == 8 and host == "mail.ru"); return "fakehost" end
rawsend_opts_base = function() return {kind="original"} end
rawsend_opts = function() return {kind="fake"} end
reconstruct_opts = function() return {} end
rawsend_payload_segmented = function(d, data, offset, opts)
    sent[#sent+1] = {data=data, offset=offset, opts=opts}
    return #sent ~= fail_at
end
local function fresh()
    sent, fail_at, missing_host, cutoff = {}, nil, false, false
    return {dis={tcp={}, payload="BEFORErealhostAFTER"}, arg={host="mail.ru", tcp_ts=-1000, tcp_ts_up=true, repeats=5}}
end
local d = fresh()
assert(next_hostfakesplit({}, d) == VERDICT_DROP and d.dropped)
assert(#sent == 4)
local expected = {{"BEFORE",0},{"fakehost",6},{"AFTER",14},{"realhost",6}}
for i, part in ipairs(expected) do
    assert(sent[i].data == part[1] and sent[i].offset == part[2], "altorder=1 packet order changed")
    assert(sent[i].opts.rawsend.kind == (i == 2 and "fake" or "original"))
    assert(sent[i].opts.fooling.tcp_ts == (i == 2 and -1000 or nil), "fooling leaked to a real segment")
end
-- Reassembled messages use the whole request, and replayed pieces are dropped.
d = fresh(); d.reasm_data = d.dis.payload; d.dis.payload = "piece"
assert(next_hostfakesplit({}, d) == VERDICT_DROP and #sent == 4)
sent = {}; d.replayed = true
assert(next_hostfakesplit({}, d) == VERDICT_DROP and #sent == 0)
-- A failed send must preserve the original and must not mark replay as sent.
for i=1,4 do
    d = fresh(); fail_at = i
    assert(next_hostfakesplit({}, d) == VERDICT_PASS and not d.dropped and #sent == i)
end
d = fresh(); d.arg.nodrop = true
assert(next_hostfakesplit({}, d) == VERDICT_PASS and d.dropped)
d = fresh(); missing_host = true
assert(next_hostfakesplit({}, d) == nil and #sent == 0)
d = fresh(); d.incoming = true
assert(next_hostfakesplit({}, d) == nil and #sent == 0)
d = fresh(); d.unknown = true
assert(next_hostfakesplit({}, d) == nil and #sent == 0)
d = fresh(); d.dis.tcp = nil; d.dis.udp = {}
assert(next_hostfakesplit({}, d) == nil and cutoff and #sent == 0)
d = fresh(); d.dis.tcp = nil; d.dis.icmp = {}
assert(next_hostfakesplit({}, d) == nil and not cutoff and #sent == 0)
for _, name in ipairs(names) do _G[name] = saved[name] end
print("ALT13 altorder=1 offline regression passed")
