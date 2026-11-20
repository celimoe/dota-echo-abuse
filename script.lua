local echo_abuse = {}

function echo_abuse:init()
	-- #region ui
	self.ui = {}

	self.ui.menu = Menu.Create("Miscellaneous", "In Game", "Echo Abuse")
	self.ui.menu:Image(LIB_RENDER.get_ability_icon_path("item_echo_sabre"))

	self.ui.menu_group = self.ui.menu:Create("Main"):Create("General", Enum.GroupSide.FullWidth)

	self.ui.enable = self.ui.menu_group:Switch("Enable", false, "\u{f00c}")
	self.ui.enable:Unsafe(true)

	self.ui.toggle_key = self.ui.menu_group:Bind("Toggle Key", Enum.ButtonCode.KEY_NONE, "\u{f11c}")
	self.ui.toggle_key:SetToggled(true)
	self.ui.toggle_key:Properties(nil, nil, true)

	self.ui.fast_echo = self.ui.menu_group:Switch("Keep Haste", false, "\u{f04e}")

	self.ui.enable:SetCallback(function (it)
		self.ui.toggle_key:Disabled(not it:Get())
		self.ui.fast_echo:Disabled(not it:Get())
	end, true)
	-- #endregion ui

	self.delays = {}

	local offsets = {}
	local unlocked = {}
	local sent_orders = {}

	local vec_zero = Vector()

	local attack = nil
	local used = nil
	local tick = nil

	local attack_activities = {
		[Enum.GameActivity.ACT_DOTA_ATTACK] = true,
		[Enum.GameActivity.ACT_DOTA_ATTACK2] = true,
		[Enum.GameActivity.ACT_DOTA_ATTACK_EVENT] = true,
		[Enum.GameActivity.ACT_DOTA_ATTACK_EVENT_BASH] = true,
		[Enum.GameActivity.ACT_DOTA_ATTACK_SPECIAL] = true,
	}

	-- #region callbacks
	CallbacksManager:set("OnUpdate", function ()
		if (not self.ui.enable:Get()) then
			return
		end

		local npc = LIB_HEROES_DATA.my_hero.ref

		if (npc == nil) then
			return
		end

		local idle = NPC.IsRanged(npc) and NPC.GetUnitName(npc) ~= "npc_dota_hero_vengefulspirit" or not self.ui.toggle_key:IsToggled()
		if (idle) then
			attack = nil
		end

		local now = ToTick(LIB_HEROES_DATA.curtime)
		local last = tick or now

		if (now ~= tick) then
			local offset = chronos.nanotime() - now * DotaConstants.tick

			if (offset - (offsets[#offsets] or offset) > 0.25) then
				offsets = {}
			end

			table.insert(offsets, offset)

			if (#offsets > 60) then
				table.remove(offsets, 1)
			end

			tick = now
		end

		local late = (offsets[#offsets] - math.min(table.unpack(offsets))) / DotaConstants.tick

		local pending = false

		local sabre = NPC.GetItem(npc, "item_echo_sabre", true)

		for i = #sent_orders, 1, -1 do
			local sent = sent_orders[i]
			local item = NPC.GetItem(npc, sent.name, false)

			if (item ~= sent.item or sent.name ~= "item_echo_sabre" and not Item.IsCombineLocked(sent.item)) then
				if (sent.first) then
					table.insert(self.delays, { now - sent.tick - 1 - sent.late, now - sent.tick - sent.late })
				end

				table.remove(sent_orders, i)

				if (#self.delays > 16) then
					table.remove(self.delays, 1)
				end
			elseif (now - sent.tick > 15) then
				unlocked[sent.item] = nil
				table.remove(sent_orders, i)
			else
				pending = pending or sent.item == sabre
			end
		end

		if (attack and not attack.landed) then
			local last_attack = Entity.GetField(npc, "m_flLastAttackTime") / DotaConstants.tick

			if (last_attack ~= attack.last_attack) then
				attack.landed = true
				local predicted_tick = attack.tick

				attack.tick = math.abs(last_attack - math.floor(last_attack + 0.5)) < 0.002 and math.floor(last_attack + 0.5) or math.min(math.max(attack.tick, last + 1), now)

				if (attack.latest < attack.tick - 1.01 or attack.earliest > attack.tick + 0.01) then
					attack.earliest, attack.latest = attack.tick - 0.999, attack.tick
				else
					attack.earliest, attack.latest = math.max(attack.earliest, attack.tick - 0.999), math.min(attack.latest, attack.tick)
				end

				if (attack.tick ~= predicted_tick) then
					attack.time = nil
				end

				used = sabre

				if (self.point_ratio) then
					local speed = NPC.GetAttackSpeed(npc)
					local attack_ticks = NPC.GetSecondsPerAttack(npc, false) / DotaConstants.tick

					local hasted = sabre and Ability.GetCooldown(sabre) > 4.85 and not (self.ui.fast_echo:Get() and attack.hasted)

					if (hasted) then
						attack_ticks = attack_ticks * speed / math.max(speed, math.min(speed + 5, 7))
					end

					attack = self:plan(npc, math.floor(last_attack + attack_ticks * (1 - self.point_ratio) + 1e-4) + 1, nil, attack, now)
					attack.hasted = hasted
				end

			elseif (NPC.GetAttackSpeed(npc) ~= attack.speed and attack.latest - attack.duration < now and now + 1 < attack.earliest) then
				local cast = attack.cast * attack.speed / NPC.GetAttackSpeed(npc)

				attack.time = nil

				attack.earliest = now + 1 + (attack.earliest - now - 1) / attack.duration * cast
				attack.latest = now + 1 + (attack.latest - now - 1) / attack.duration * cast
				attack.tick, attack.cast, attack.duration, attack.speed = math.ceil((attack.earliest + attack.latest) / 2 - 0.001), cast, cast, NPC.GetAttackSpeed(npc)
			end
		end

		local reach = math.ceil(self:send_ticks() + late)

		if (sabre) then
			if (not idle and not (attack and not attack.landed and sabre == used and (self.ui.fast_echo:Get() and attack.hasted or now + 2 * reach > attack.tick)) and (not attack or sabre == used or now + reach > attack.tick or now < attack.start) and not pending) then
				unlocked = {}

				table.insert(sent_orders, { item = sabre, name = Ability.GetName(sabre), tick = now, late = late, first = #sent_orders == 0 or sent_orders[#sent_orders].tick ~= now })

				Player.PrepareUnitOrders(
					LIB_HEROES_DATA.my_hero.player_ref,
					Enum.UnitOrder.DOTA_UNIT_ORDER_DISASSEMBLE_ITEM,
					nil,
					vec_zero,
					sabre,
					Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY,
					npc,
					false,
					false,
					false,
					false,
					"celi.echo_abuse"
				)
			end

			return
		end

		for i, name in ipairs({ "item_ogre_axe", "item_broadsword", "item_void_stone" }) do
			local item = NPC.GetItem(npc, name, false)

			if (item and Item.IsCombineLocked(item) and not unlocked[item]) then
				if (i < 3 or idle or attack and not attack.landed and (not attack.hasted or not self.ui.fast_echo:Get() and attack.cast < reach + 1) and now <= attack.tick and now + reach >= attack.tick) then
					unlocked[item] = true

					table.insert(sent_orders, { item = item, name = Ability.GetName(item), tick = now, late = late, first = #sent_orders == 0 or sent_orders[#sent_orders].tick ~= now })

					Player.PrepareUnitOrders(
						LIB_HEROES_DATA.my_hero.player_ref,
						Enum.UnitOrder.DOTA_UNIT_ORDER_SET_ITEM_COMBINE_LOCK,
						nil,
						vec_zero,
						item,
						Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY,
						npc,
						false,
						false,
						false,
						false,
						"celi.echo_abuse"
					)
				end
			end
		end
	end, "celi.echo_abuse")

	CallbacksManager:set("OnUnitAnimation", function (data)
		local npc = LIB_HEROES_DATA.my_hero.ref

		if (npc == nil) then
			return
		end

		if (data.unit ~= npc) then
			return
		end

		if (NPC.IsRanged(data.unit) and NPC.GetUnitName(data.unit) ~= "npc_dota_hero_vengefulspirit") then
			return
		end

		if (not attack_activities[data.activity]) then
			return
		end

		local now = ToTick(GameRules.GetGameTime())
		local hasted = self.ui.fast_echo:Get() and attack and not attack.landed and attack.hasted

		self.point_ratio = math.max(self.point_ratio or 0, data.castpoint / NPC.GetSecondsPerAttack(data.unit, false))
		attack = self:plan(data.unit, now, data.castpoint / DotaConstants.tick, attack and (attack.landed and attack or attack.previous), now)
		attack.hasted = hasted
	end, "celi.echo_abuse")
	-- #endregion callbacks

	return {}
end

local function float32(x) return (string.unpack("f", string.pack("f", x))) end
function echo_abuse:plan(npc, start, cast_point, previous, now)
	local attack_ticks = NPC.GetSecondsPerAttack(npc, false) / DotaConstants.tick
	local cast = cast_point or attack_ticks * self.point_ratio
	local earliest, latest = start + cast, start + cast

	local tick_time = float32(DotaConstants.tick)
	local carry = 0

	if (previous and start - previous.tick < attack_ticks) then
		earliest, latest = earliest - (previous.tick - previous.earliest), latest - (previous.tick - previous.latest)
		carry = previous.time and float32(float32(previous.tick * tick_time) - previous.time)
	end

	local time = cast_point and carry and float32(float32(start * tick_time) + float32(float32(cast_point * DotaConstants.tick) - carry))
	local tick = math.ceil((earliest + latest) / 2 - 0.001)

	if (time) then
		tick = math.ceil(time / tick_time) - 1

		while (float32(tick * tick_time) < time) do
			tick = tick + 1
		end
	end

	return {
		time = time,
		earliest = earliest,
		latest = latest,
		tick = tick,
		cast = cast,
		duration = (earliest + latest) / 2 - start,
		speed = NPC.GetAttackSpeed(npc),
		start = math.max(tick - math.ceil(self:send_ticks()) - 1, now),
		last_attack = Entity.GetField(npc, "m_flLastAttackTime") / DotaConstants.tick,
		previous = previous,
	}
end

function echo_abuse:send_ticks()
	if (#self.delays == 0) then
		return NetChannel.GetLatency(Enum.Flow.FLOW_OUTGOING) / DotaConstants.tick + 0.68
	end

	local edges = {}

	for _, delay in ipairs(self.delays) do
		table.insert(edges, { delay[1], 1 })
		table.insert(edges, { delay[2], -1 })
	end

	table.sort(edges, function (a, b)
		return a[1] < b[1] or a[1] == b[1] and a[2] < b[2]
	end)

	local count, best, value = 0, 0, 0

	for i, edge in ipairs(edges) do
		count = count + edge[2]

		if (count > best) then
			best, value = count, (edge[1] + edges[i + 1][1]) / 2
		end
	end

	return value
end

return echo_abuse:init()
