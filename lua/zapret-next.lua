-- Derived from bol-van's MIT-licensed hostfakesplit in zapret-antidpi.lua.
-- ALT13 needs the legacy altorder=1 order: before, fake host, after, real host.
-- Keep the pinned upstream libraries unchanged; all helpers are provided by them.
function next_hostfakesplit(ctx, desync)
    if not desync.dis.tcp then
        if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
        return
    end
    direction_cutoff_opposite(ctx, desync)
    local data = desync.reasm_data or desync.dis.payload
    if #data > 0 and direction_check(desync) and payload_check(desync) then
        if replay_first(desync) then
            local pos = resolve_range(data, desync.l7payload, "host,endhost-1", true)
            if pos then
                local orig = {
                    rawsend = rawsend_opts_base(desync), reconstruct = {}, ipfrag = {},
                    ipid = desync.arg, fooling = {tcp_ts_up = desync.arg.tcp_ts_up}
                }
                local fake_opts = {
                    rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync),
                    ipfrag = {}, ipid = desync.arg, fooling = desync.arg
                }
                DLOG("next_hostfakesplit: altorder=1 host range " .. pos[1] .. "-" .. pos[2])
                if not rawsend_payload_segmented(desync, string.sub(data, 1, pos[1]-1), 0, orig) then return VERDICT_PASS end
                local fakehost = genhost(pos[2]-pos[1]+1, desync.arg.host)
                if not rawsend_payload_segmented(desync, fakehost, pos[1]-1, fake_opts) then return VERDICT_PASS end
                if not rawsend_payload_segmented(desync, string.sub(data, pos[2]+1), pos[2], orig) then return VERDICT_PASS end
                if not rawsend_payload_segmented(desync, string.sub(data, pos[1], pos[2]), pos[1]-1, orig) then return VERDICT_PASS end
                replay_drop_set(desync)
                return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
            end
        end
        if replay_drop(desync) then
            return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
        end
    end
end
