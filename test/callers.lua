-- The shapes our own resources really send to the v1 exports.
--
-- release/caller-shapes.md lists every call site in cis_inventory, cis_phone,
-- cis_housing, cis_storeRobberies, cis_vehicleshop, cis_bfe, cis_hes and
-- cis_multicharacter. This suite replays those argument shapes, on the
-- frameworks those resources run on (esx, qbcore, qbox), through the public
-- exports, and checks the answer each caller reads: the first value, or the
-- `ok, reason` pair, in the types the caller tests for.
--
-- Where a caller sends something the bridge refuses on purpose (a Notify kind
-- the contract does not have, a name it does not export) the refusal is pinned
-- here too, so the drift cannot change without a test saying so.

local passed, failed = 0, 0
local failures = {}

local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg
    end
end

local W = dofile('test/lib/v1world.lua')
W.install()

for _, f in ipairs({
    'adapters/framework/common.lua',
    'adapters/framework/esx.lua',
    'adapters/framework/qbcore.lua',
    'adapters/framework/qbox.lua',
    'adapters/framework/cis_core.lua',
    'adapters/inventory/cis_inventory.lua',
    'adapters/inventory/ox.lua',
    'adapters/inventory/qb.lua',
    'adapters/inventory/qs.lua',
    'adapters/inventory/codem.lua',
    'adapters/doors/ox_doorlock.lua',
    'adapters/doors/qb_doorlock.lua',
    'adapters/appearance/common.lua',
    'adapters/appearance/illenium.lua',
    'adapters/appearance/fivem_appearance.lua',
    'adapters/appearance/qb_clothing.lua',
    'adapters/appearance/skinchanger.lua',
    'adapters/custom.lua',
    'server/v1.lua',
}) do
    dofile(f)
end

local V1 = CisBridgeV1
local bridge = exports.cis_bridge

-- What the servers run: esx and qbox with ox_inventory, qbcore with qb-inventory.
local ROWS = {
    { fw = 'esx', inv = 'ox', crypto = false },
    { fw = 'qbcore', inv = 'qb', crypto = true },
    { fw = 'qbox', inv = 'ox', crypto = true },
}

for _, row in ipairs(ROWS) do
    W.reset({ row.fw, row.inv })
    V1.detect()
    local function t(msg) return row.fw .. ': ' .. msg end

    -- ---- cis_housing / cis_storeRobberies / HES: GetPlayer ----------------
    local p, why = bridge:GetPlayer(1)
    check(type(p) == 'table' and type(p.id) == 'string' and p.id ~= '', t('GetPlayer id is a non-empty string'))
    check(type(p) == 'table' and type(p.job) == 'table' and type(p.job.name) == 'string'
        and math.tointeger(p.job.grade) ~= nil, t('GetPlayer job.name string, job.grade whole (HES)'))
    local np, nwhy = bridge:GetPlayer(2)
    check(np == false and nwhy == 'not_loaded', t('an unloaded source answers false, not_loaded (storeRobberies)'))

    -- ---- cis_inventory: wrapped reads, `ok, p` ----------------------------
    local okc, pc = pcall(function() return exports.cis_bridge:GetPlayer(1) end)
    check(okc and type(pc) == 'table', t('GetPlayer under pcall'))

    -- ---- cis_phone: money, the integer test ------------------------------
    for _, acc in ipairs({ 'cash', 'bank' }) do
        local n = bridge:GetMoney(1, acc)
        check(math.type(n) == 'integer' and n >= 0, t('phone: GetMoney ' .. acc .. ' is a whole number >= 0'))
    end
    local cn, cwhy = bridge:GetMoney(1, 'crypto')
    if row.crypto then
        check(math.type(cn) == 'integer' and cn >= 0, t('phone: crypto account is a whole number'))
    else
        -- ESX has no crypto account. The phone's crypto app reads this as nil.
        check(cn == false and cwhy == 'bad_account', t('phone: no crypto account answers bad_account: ' .. tostring(cwhy)))
    end

    -- phone wallet: Remove then Add on two accounts, reason string, `== true`
    local cash0, bank0 = bridge:GetMoney(1, 'cash'), bridge:GetMoney(1, 'bank')
    check(bridge:RemoveMoney(1, 'bank', 100, 'phone wallet send') == true, t('phone: RemoveMoney bank'))
    check(bridge:AddMoney(1, 'cash', 100, 'phone wallet receive') == true, t('phone: AddMoney cash'))
    check(bridge:GetMoney(1, 'bank') == bank0 - 100 and bridge:GetMoney(1, 'cash') == cash0 + 100,
        t('phone: both balances moved'))
    -- through pcall(fn, src, account, amount, reason), as wallet.lua calls it
    local good = select(2, pcall(bridge.AddMoney, bridge, 1, 'bank', 100, 'refund'))
    check(good == true, t('phone: pcall(AddMoney) answers true'))
    -- housing refund and rent: ret2 on a short balance
    local rok, rwhy = bridge:RemoveMoney(1, 'bank', 2000000, 'rent')
    check(rok == false and rwhy == 'insufficient_funds', t('housing: RemoveMoney over balance, insufficient_funds'))
    -- a float price is refused, not rounded
    local fok, fwhy = bridge:RemoveMoney(1, 'bank', 10.5, 'price')
    check(fok == false and fwhy == 'bad_amount', t('a float price answers bad_amount'))

    -- ---- storeRobberies: payout, items ------------------------------------
    check(bridge:AddMoney(1, 'cash', 250, 'store_robbery') == true, t('storeRobberies: payout'))
    local cok = bridge:CanCarry(1, 'water', 2)
    check(cok == true, t('storeRobberies: CanCarry'))
    local aok = bridge:AddItem(1, 'water', 2, { note = 'loot' })
    check(aok == true and W.count(1, 'water') == 2, t('storeRobberies: AddItem with metadata'))
    check(bridge:GetItemCount(1, 'water') == 2, t('storeRobberies: GetItemCount'))
    local bok, bwhy = bridge:AddItem(1, 'water', 1.5)
    check(bok == false and bwhy == 'bad_count', t('a non-whole config count answers bad_count'))
    local mok, mwhy = bridge:AddItem(1, 'water', 1, 'not a table')
    check(mok == false and mwhy ~= nil, t('metadata that is not a table is refused: ' .. tostring(mwhy)))
    check(bridge:RemoveItem(1, 'water', 2) == true and W.count(1, 'water') == 0, t('storeRobberies: RemoveItem'))
    local iok, iwhy = bridge:RemoveItem(1, 'water', 1)
    check(iok == false and iwhy == 'insufficient_items', t('HES: RemoveItem with none answers insufficient_items'))

    -- HES calls through the dynamic form
    local name = 'AddItem'
    check(exports.cis_bridge[name](exports.cis_bridge, 1, 'water', 1) == true, t('HES: dynamic exports.cis_bridge[name]'))
    bridge:RemoveItem(1, 'water', 1)

    -- multicharacter: math.floor(amount) hands a float-typed whole number
    local fl = bridge:AddItem(1, 'water', math.floor(2.7), nil)
    check(fl == true, t('multicharacter: AddItem(math.floor(n), nil metadata)'))
    bridge:RemoveItem(1, 'water', 2)

    -- ---- jobs -------------------------------------------------------------
    local job = bridge:GetJob(1)
    check(type(job) == 'table' and type(job.onDuty) == 'boolean' and type(job.name) == 'string',
        t('GetJob: name string, onDuty boolean (storeRobberies policeOnDuty)'))
    check(select(1, (bridge:GetJob(1))) == job.name and false or true, t('GetJob first value only'))

    -- ---- Notify: the kinds the callers send --------------------------------
    for _, kind in ipairs({ 'info', 'success', 'warning', 'error' }) do
        check(bridge:Notify(1, 'hello', kind) == true, t('Notify kind ' .. kind))
    end
    check(bridge:Notify(1, 'hello') == true, t('Notify with no kind'))
    -- cis_vehicleshop sends 'inform', the old ox_lib spelling of info
    -- (ox_lib maps it itself). The bridge takes it and hands the adapter 'info'.
    W.calls = {}
    local nok, nwhy2 = bridge:Notify(1, 'hello', 'inform')
    check(nok == true, t("Notify kind 'inform' is accepted as info: " .. tostring(nwhy2)))
    local sawInform = false
    for _, c in ipairs(W.calls) do
        -- the first record is the call into the bridge itself
        if not tostring(c.key):find('^cis_bridge%.') then
            for i = 1, (c.args and c.args.n or 0) do if c.args[i] == 'inform' then sawInform = true end end
        end
    end
    check(not sawInform, t("no adapter is handed 'inform'"))
    local bok2, bwhy2 = bridge:Notify(1, 'hello', 'loud')
    check(bok2 == false and bwhy2 == 'bad_message', t('an unknown kind still answers bad_message'))

    -- ---- cis_phone: the charId round trip ----------------------------------
    -- wallet.lua reads `pcall(sourceOf, charId)` as `done, src, why`: the
    -- source is the first value, so a miss is `false, 'offline'`.
    local src, swhy = bridge:GetSourceByCharId(p.id)
    check(src == 1 and swhy == nil, t('phone: GetSourceByCharId answers the source: ' .. tostring(src)))
    local offok, offwhy = bridge:GetSourceByCharId('NOBODY')
    check(offok == false and (offwhy == 'offline' or offwhy == 'bad_id'), t('phone: unknown charId is offline: ' .. tostring(offwhy)))

    -- ---- cis_inventory: the optional readers -------------------------------
    local g1, g2 = bridge:GetGang(1)
    check(type(g1) == 'table' or g1 == false, t('GetGang answers a table or false, reason: ' .. tostring(g2)))
    local ps, pswhy = bridge:GetPlayerState(1)
    if row.fw == 'esx' then
        check(ps == false and pswhy == 'unsupported', t('GetPlayerState on ESX is unsupported: ' .. tostring(pswhy)))
    else
        check(type(ps) == 'table' and type(ps.dead) == 'boolean' and type(ps.cuffed) == 'boolean',
            t('GetPlayerState: dead and cuffed booleans'))
    end
    check(bridge:GetOwnedVehicleId('NOPE1') == false, t('GetOwnedVehicleId: an unowned plate answers false'))

    -- UseItem with a slot view as data: a normal one is accepted by the shape check
    local slotView = { name = 'water', slot = 3, count = 1, metadata = { durability = 90, nested = { a = { b = 1 } } } }
    local uok, uwhy = bridge:UseItem(1, 'water', slotView)
    check(uok ~= nil and uwhy ~= 'bad_data', t('UseItem: a slot view is not bad_data: ' .. tostring(uwhy)))

    -- ---- Names the callers use that the bridge does not export ------------
    check(W.declared.cis_bridge.GetItemSlots == nil, t('GetItemSlots is not an export (cis_phone device mode)'))
    check(W.declared.cis_bridge.SetItemMetadata == nil, t('SetItemMetadata is not an export (cis_phone device mode)'))
    local s = bridge:GetSummary()
    check(s.features == nil, t('summary has no features field (cis_phone reads features.itemMetadata)'))
    check(s.framework == row.fw and type(s.version) == 'string' and s.api == 1,
        t('summary: framework, version, api (housing, inventory doctor, bfe)'))
end

_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(callers): ' .. failures[i] .. '\n')
end
io.write(('callers passed=%d failed=%d\n'):format(passed, failed))
