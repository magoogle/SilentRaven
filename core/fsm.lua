-- core/fsm.lua  --  the turn-in state machine
--
-- States (tracker.state):
--   nil              idle, no run in flight
--   'TELEPORTING'    cast TP-to-Skov_Temis, waiting for zone change
--   'WALK_NPC'       moving toward Tree NPC (live-stream actor)
--   'INTERACT_NPC'   re-firing interact_object until panel verifies open
--   'API_CLAIMING'   used quest_reward.pick_and_accept; verify quest gone
--   'WAIT_RETRY'     short pause between retries
--   'DONE'           terminal success; fires callback next tick
--   'FAILED'         terminal failure; fires callback next tick
--
-- Reward selection is API-only: quest_reward.pick_and_accept(idx).
-- The pixel-click fallback path was removed -- if the host doesn't
-- expose the API, the run fails fast with a clear error rather than
-- chasing screen coordinates.
--
-- Per-frame budget: every branch is O(1) state checks plus at most one
-- quest scan + actor scan.  No allocations in the hot path; no os.execute
-- or io.popen.  See feedback_lua_perf.md for why this matters.

local log      = require 'core.log'
local whispers = require 'core.whispers'
local tracker  = require 'core.tracker'
local rewards  = require 'core.rewards'
local stats    = require 'core.stats'

local M = {}

-- Tunables
local INTERACT_RANGE              = 30.0    -- D4 walks the last few yards
local TELEPORT_TIMEOUT_S          = 30.0
local TELEPORT_RECAST_DEBOUNCE_S  = 3.0     -- mirrors AlfredTheButler/teleport.lua
local TELEPORT_SPELL_ID           = 186139  -- "casting town portal" anim
-- WALK_NPC has its own (longer) timeout because right after TP the NPC
-- actor isn't in stream yet -- we need time to walk to the static
-- intermediate waypoint AND then to the NPC pos before bailing.
-- INTERACT_NPC keeps the original 10s -- that's just panel-render after
-- a successful interact.
local WALK_NPC_TIMEOUT_S          = 20.0
local NPC_PANEL_TIMEOUT_S         = 10.0
local INTERACT_RETRY_INTERVAL_S   = 1.5
local CLAIM_VERIFY_TIMEOUT_S      = 5.0
local INTER_ATTEMPT_S             = 1.5
local MAX_RETRIES                 = 3

-- Per-zone latch logic: once we successfully turn in, set last_zone_handled.
-- Drop the latch the moment the player leaves that zone.  Without this,
-- the gate sticks across every TP back to town.
local function update_zone_latch(cur_zone)
    if cur_zone == tracker.last_observed_zone then return end
    if tracker.last_observed_zone == tracker.last_zone_handled then
        tracker.last_zone_handled = nil
    end
    tracker.last_observed_zone = cur_zone
end

-- Best-effort path-to-actor.  Prefers pathfinder.request_move (the
-- per-frame friendly "request if not already moving" variant -- same
-- choice as WarMachine's navigator) over move_to_cpathfinder which
-- recomputes a custom path on every call and stutters when invoked
-- per frame.  No-op if neither is exposed on this host.
local function move_toward_actor(actor)
    if not actor or not actor.get_position then return end
    local p = actor:get_position()
    if not p then return end
    if pathfinder then
        if pathfinder.request_move then
            pcall(pathfinder.request_move, p)
            return
        end
        if pathfinder.move_to_cpathfinder then
            pcall(pathfinder.move_to_cpathfinder, p)
        end
    end
end

local function in_interact_range(actor)
    return whispers.player_dist_sq(actor) <= INTERACT_RANGE * INTERACT_RANGE
end

-- Begin a fresh attempt.  Increments the attempt counter; the caller is
-- responsible for setting tracker.state to whatever the next stage is.
local function begin_attempt(settings)
    tracker.attempts          = (tracker.attempts or 0) + 1
    tracker.interacts_fired   = 0
    tracker.last_interact_t   = nil
    tracker.interact_npc      = nil
    -- Re-randomize the intermediate waypoint each attempt -- if the
    -- last one led to a stuck path, a different point may unstick.
    tracker.walk_intermediate = nil
    log.debug(settings, string.format('attempt %d/%d', tracker.attempts, MAX_RETRIES))
end

-- Drop the FSM into WAIT_RETRY (or FAILED if out of retries).  Always
-- sends Escape first so any partial UI is closed before the next attempt.
local function fail_or_retry(now, reason, settings)
    whispers.send_escape()
    if tracker.attempts >= MAX_RETRIES then
        log.info(string.format('giving up: %s (after %d attempt(s))', reason, tracker.attempts))
        tracker.state   = 'FAILED'
        tracker.state_t = now
        return
    end
    log.debug(settings, 'retry: ' .. reason)
    tracker.state   = 'WAIT_RETRY'
    tracker.state_t = now
end

-- Resolve which reward index to claim.  Always priority-based now --
-- pick_best_index handles its own "first valid entry" fallback when
-- nothing scores above 0, so we never need a separate fixed-index
-- backup.  Returns (index, reason) or (nil, error_string) on failure.
local function resolve_pick_index(settings)
    if not (quest_reward and type(quest_reward.enumerate) == 'function') then
        return nil, 'quest_reward.enumerate unavailable on this host'
    end
    local ok, entries = pcall(quest_reward.enumerate)
    if not ok or type(entries) ~= 'table' then
        return nil, 'quest_reward.enumerate failed'
    end
    local best, score, breakdown = rewards.pick_best_index(entries, settings)
    if settings.debug then
        for i = 1, #breakdown do
            local b = breakdown[i]
            log.debug(settings, string.format(
                '  pick: [%s] %s slot=%s legendary=%s score=%d (%s)%s',
                tostring(b.index), b.display_name, b.slot,
                tostring(b.legendary), b.score, b.evidence,
                b.fallback and ' <-- FALLBACK' or ''))
        end
    end
    if not best then
        return nil, 'no entries on offer'
    end
    if score == 0 then
        return best, 'priority(fallback first-valid)'
    end
    return best, string.format('priority(score=%d)', score)
end

-- Fire the reward selection via quest_reward.pick_and_accept.  No
-- fallback -- if the API isn't available or the call fails, the
-- attempt fails and the FSM goes through fail_or_retry.
--
-- Also caches the picked entry on tracker so finalize() can bump the
-- per-slot / legendary counters in core.stats once the claim verifies.
local function fire_claim(settings, now)
    if not whispers.has_quest_reward_api() then
        fail_or_retry(now, 'quest_reward API not exposed by this host', settings)
        return
    end
    local idx, reason = resolve_pick_index(settings)
    if not idx then
        fail_or_retry(now, 'pick_index: ' .. tostring(reason), settings)
        return
    end

    -- Snapshot the entry NOW (before pick_and_accept) so we have the
    -- slot/legendary/name available for stats even if the post-claim
    -- enumerate() returns differently after the host advances state.
    local entries_ok, entries = pcall(quest_reward.enumerate)
    if entries_ok and type(entries) == 'table' and entries[idx] then
        local e = entries[idx]
        tracker.last_pick_entry = {
            slot      = rewards.extract_slot(e),
            legendary = rewards.is_legendary(e),
            name      = rewards.display_name(e),
        }
    else
        tracker.last_pick_entry = nil
    end

    local ok, ret = pcall(quest_reward.pick_and_accept, idx)
    if ok and ret then
        log.debug(settings, string.format('quest_reward.pick_and_accept(%d) ok [%s]', idx, reason))
        tracker.state   = 'API_CLAIMING'
        tracker.state_t = now
        return
    end
    -- Pick failed at the API level -- discard the snapshot so finalize
    -- doesn't credit it as claimed.
    tracker.last_pick_entry = nil
    fail_or_retry(now, string.format('pick_and_accept(%d) returned %s', idx, tostring(ret)), settings)
end

-- Terminal-state finalize: fire callback, log, reset.  After this, FSM is
-- back to idle; the next tick won't re-enter any state branch.
--
-- Always abort any in-flight pathfinder movement here so the bot stops
-- where it is instead of drifting to its last requested goal after the
-- run is "over".  Prior to this, calling pathfinder.move_to_cpathfinder
-- meant the bot kept walking even after FSM transitioned to idle.
--
-- Why we latch the zone on FAILURE too: without it, the autofire loop in
-- main.lua sees `ready == true` + in-town + no latch and immediately
-- re-fires the FSM on the next pulse, busy-looping on whatever caused
-- the failure (panel won't open, NPC dropped from stream, etc.) until
-- the player leaves and re-enters the zone.  Matches WarMachine's
-- behavior in tasks/warplan/whisper_turnin.lua.
local function finalize(settings, cur_zone, success)
    local cb     = tracker.external_callback
    local result = success and 'success' or 'failed'
    log.info(string.format('run finished: %s (%d attempt(s), reason=%s)',
        result, tracker.attempts, tracker.last_reason or ''))
    tracker.last_zone_handled = cur_zone
    tracker.last_result       = result
    tracker.last_result_t     = (get_time_since_inject and get_time_since_inject()) or 0
    tracker.all_task_done     = true

    -- Stats + D4Remote loot record on success -- before reset_run
    -- nukes tracker.last_pick_entry.
    if success and tracker.last_pick_entry then
        local ent = tracker.last_pick_entry
        stats.bump_success(ent.slot, ent.legendary, ent.name, tracker.last_reason)
        if D4Remote and D4Remote.record_loot then
            local cat = (rewards.SLOT_TO_D4REMOTE_CATEGORY and rewards.SLOT_TO_D4REMOTE_CATEGORY[ent.slot])
                     or 'cache'
            local rarity = ent.legendary and 5 or 4   -- 5=Legendary, 4=Rare
            pcall(D4Remote.record_loot, cat, rarity)
            log.debug(settings, string.format(
                'D4Remote.record_loot(%s, %d) for %s', cat, rarity, ent.name or '?'))
        end
    elseif not success then
        stats.bump_failure(tracker.last_reason)
    end

    whispers.stop_movement()
    tracker.reset_run()
    if cb then
        pcall(cb, result)
    end
end

-- Single tick.  Called from main_pulse every frame while a run is in
-- flight.  Keep every branch O(1) plus at most one quest scan / actor
-- scan -- nothing in here may iterate large state.
M.tick = function (settings)
    -- Pause acts as a soft freeze: no progression, but state is preserved.
    -- A later resume() picks up where we left off (with the same caller's
    -- callback still pending).
    if tracker.paused then return end

    local now      = (get_time_since_inject and get_time_since_inject()) or 0
    local cur_zone = whispers.current_zone()
    update_zone_latch(cur_zone)

    -- ---- Terminal states fire callback then reset ----
    if tracker.state == 'DONE' then
        finalize(settings, cur_zone, true)
        return
    end
    if tracker.state == 'FAILED' then
        finalize(settings, cur_zone, false)
        return
    end

    -- ---- WAIT_RETRY: short pause then fall through into next attempt ----
    if tracker.state == 'WAIT_RETRY' then
        if (now - (tracker.state_t or 0)) < INTER_ATTEMPT_S then return end
        tracker.state   = nil
        tracker.state_t = nil
        -- fall through to "state == nil" branch below
    end

    -- ---- TELEPORTING: re-cast on debounce, wait for arrival ----
    if tracker.state == 'TELEPORTING' then
        if cur_zone == 'Skov_Temis' then
            log.debug(settings, 'arrived in Skov_Temis')
            tracker.state   = nil    -- start a fresh attempt in town
            tracker.state_t = nil
            -- fall through to "state == nil" branch below
        else
            local elapsed = now - (tracker.state_t or 0)
            if elapsed >= TELEPORT_TIMEOUT_S then
                log.info('teleport timed out')
                tracker.state   = 'FAILED'
                tracker.state_t = now
                return
            end
            -- Re-cast TP if not currently casting and debounce elapsed.
            local lp = get_local_player and get_local_player() or nil
            local casting = false
            if lp and lp.get_active_spell_id then
                local sid = lp:get_active_spell_id()
                if sid == TELEPORT_SPELL_ID then casting = true end
            end
            if (not casting)
                and teleport_to_waypoint
                and (now - (tracker.tp_last_cast_t or -math.huge)) >= TELEPORT_RECAST_DEBOUNCE_S
            then
                pcall(teleport_to_waypoint, settings.teleport_target_sno or 0x1CE51E)
                tracker.tp_last_cast_t = now
                stats.bump_tp()
                log.debug(settings, 'teleport_to_waypoint cast')
            end
            return
        end
    end

    -- After this point we expect to be in a whisper town.  If we drift
    -- out mid-sequence (mount + zone change), bail.
    if tracker.state ~= nil and not whispers.in_whisper_town() then
        log.info('left whisper town mid-sequence -- aborting')
        tracker.state   = 'FAILED'
        tracker.state_t = now
        return
    end

    -- ---- API_CLAIMING: panel was claimed via API; verify quest gone ----
    if tracker.state == 'API_CLAIMING' then
        if not whispers.is_bounty_quest_present() then
            tracker.state   = 'DONE'
            tracker.state_t = now
            return
        end
        if (now - (tracker.state_t or 0)) < CLAIM_VERIFY_TIMEOUT_S then return end
        fail_or_retry(now, 'quest still in log after API claim', settings)
        return
    end

    -- ---- WALK_NPC: moving to NPC; transition to INTERACT_NPC when close ----
    --
    -- Two walk targets, chosen per tick:
    --   * NPC actor  -- if it's in the live stream, walk straight to it.
    --   * Static fallback -- intermediate waypoint until we're close,
    --     then the known NPC position.  Used when the actor hasn't
    --     populated the stream yet (typical right after TP).
    if tracker.state == 'WALK_NPC' then
        local npc = tracker.interact_npc
        if not npc or not (npc.is_interactable and npc:is_interactable()) then
            npc = whispers.find_tree_npc()
            tracker.interact_npc = npc
        end

        -- In range of actor -> fire interact and transition.
        if npc and in_interact_range(npc) then
            pcall(interact_object, npc)
            tracker.interacts_fired = 1
            tracker.last_interact_t = now
            tracker.state           = 'INTERACT_NPC'
            tracker.state_t         = now
            log.debug(settings, 'in range; first interact_object fired')
            return
        end

        -- Walk: actor-driven if found, else static fallback (only in
        -- zones we have coords for; other towns just wait for actor).
        if npc then
            move_toward_actor(npc)
        elseif whispers.has_known_coords(cur_zone) then
            if not tracker.walk_intermediate then
                tracker.walk_intermediate = whispers.choose_intermediate()
                log.debug(settings, string.format(
                    'NPC not in stream; walking via intermediate (%.1f, %.1f, %.1f)',
                    tracker.walk_intermediate.x,
                    tracker.walk_intermediate.y,
                    tracker.walk_intermediate.z))
            end
            local d_int = whispers.player_dist_to_pos(tracker.walk_intermediate)
            if d_int > whispers.INTERMEDIATE_ARRIVAL_RADIUS then
                whispers.move_to_pos(tracker.walk_intermediate)
            else
                whispers.move_to_pos(whispers.RAVEN_NPC_POSITION)
            end
        end

        -- Timeout: if the NPC still isn't in stream after we've walked
        -- through the intermediate AND tried the NPC position, give up
        -- this attempt.  20s gives time for ~16y walk + actor populate.
        if (now - (tracker.state_t or 0)) >= WALK_NPC_TIMEOUT_S then
            if not npc then
                fail_or_retry(now, 'NPC never appeared in stream after walk', settings)
            end
        end
        return
    end

    -- ---- INTERACT_NPC: re-fire interact on cadence; verify panel open ----
    if tracker.state == 'INTERACT_NPC' then
        if whispers.reward_panel_open() then
            log.debug(settings, 'reward panel verified open')
            fire_claim(settings, now)
            return
        end
        local elapsed = now - (tracker.state_t or 0)
        if elapsed >= NPC_PANEL_TIMEOUT_S then
            fail_or_retry(now, 'reward panel never opened', settings)
            return
        end
        if (now - (tracker.last_interact_t or 0)) >= INTERACT_RETRY_INTERVAL_S then
            local npc = tracker.interact_npc
            if not npc or not (npc.is_interactable and npc:is_interactable()) then
                npc = whispers.find_tree_npc()
                tracker.interact_npc = npc
            end
            if npc then
                pcall(interact_object, npc)
                tracker.interacts_fired = (tracker.interacts_fired or 0) + 1
                tracker.last_interact_t = now
                log.debug(settings, 'interact_object re-fire #' .. tracker.interacts_fired)
            end
        end
        return
    end

    -- ---- state == nil: starting fresh attempt ----
    -- If the panel is somehow already open (manual interact, sticky from
    -- prior run), skip straight to claim.
    if whispers.reward_panel_open() then
        begin_attempt(settings)
        fire_claim(settings, now)
        return
    end

    -- Find the NPC; walk if too far, interact if in range.
    local npc = whispers.find_tree_npc()
    if not npc then
        -- Edge case: in town but NPC not in stream yet (just-arrived).
        -- Bump the attempt counter and park in WALK_NPC -- the WALK_NPC
        -- branch will retry the find on subsequent ticks.
        begin_attempt(settings)
        tracker.interact_npc = nil
        tracker.state        = 'WALK_NPC'
        tracker.state_t      = now
        log.debug(settings, 'NPC not yet in stream; parking in WALK_NPC to retry')
        return
    end
    begin_attempt(settings)
    tracker.interact_npc = npc
    if in_interact_range(npc) then
        pcall(interact_object, npc)
        tracker.interacts_fired = 1
        tracker.last_interact_t = now
        tracker.state           = 'INTERACT_NPC'
        tracker.state_t         = now
        log.debug(settings, 'NPC in range at start; interact fired')
    else
        move_toward_actor(npc)
        tracker.state   = 'WALK_NPC'
        tracker.state_t = now
        log.debug(settings, 'walking to NPC')
    end
end

-- Kick off a new run.  Sets state to 'TELEPORTING' if `with_tp` and the
-- player isn't already in a whisper town; otherwise jumps straight into
-- the in-town flow on the next tick.
M.start = function (settings, reason, with_tp, callback)
    tracker.running         = true
    tracker.last_reason     = reason or 'auto'
    tracker.external_callback = callback
    tracker.attempts        = 0
    tracker.all_task_done   = false
    local now = (get_time_since_inject and get_time_since_inject()) or 0
    if with_tp and not whispers.in_whisper_town() then
        tracker.state           = 'TELEPORTING'
        tracker.state_t         = now
        tracker.tp_last_cast_t  = nil    -- force immediate first cast
        log.info('starting run with TP-to-Temis (reason=' .. tracker.last_reason .. ')')
    else
        tracker.state   = nil    -- next tick falls into start-of-attempt
        tracker.state_t = nil
        log.info('starting run in town (reason=' .. tracker.last_reason .. ')')
    end
end

-- True while a run is in flight (i.e. callers should yield).
M.is_running = function ()
    return tracker.running == true
end

return M
