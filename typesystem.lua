local class = {}
local root = {}
local mark_flag = true
local objects = {}
local object_ids = {}
local object_id = 0
local proxy = setmetatable({}, { __mode = "k" })
local proxy_mt = {}
local recycle_mt = { __mode = "kv" }
local typemethod = {}
local typeclass = { __index = typemethod }

function typeclass.__call(c, proto)	-- define class
	local name = c.name
	local lastdefine = c.defined
	if lastdefine then
		error(string.format("%s was defined at %s", name, lastdefine))
	end
	c.defined = debug.traceback()
	for k,v in pairs(proto) do
		assert(type(k) == "string")
		if k == "_ctor" then
			assert(c.ctor == nil)
			c.ctor = v
		elseif k == "_dtor" then
			assert(c.dtor == nil)
			c.dtor = v
		else
			local vt = type(v)
			if vt == "number" or vt == "string" or vt == "boolean" then
				c.field[k] = v
			elseif vt == "table" and getmetatable(v) == typeclass then
				local weak = k:match("^weak_(.+)")
				if weak then
					k = weak
					c.weak[weak] = v
				else
					c.ref[k] = v
				end
			else
				error(string.format("Invalid field %s with type %s", k, vt))
			end
			assert(c.keys[k] == nil)
			c.keys[k] = true
		end
	end
	return c
end

local function link_proxy(p, field, obj)
	local self = proxy[p]
	local t = self.type.ref[field]
	local is_weak
	if not t then
		t = self.type.weak[field]
		if not t then
			error(string.format("Invalid field %s", field))
		end
		is_weak = true
	end
	if obj then
		local tp = obj._ref
		if not tp then
			error(string.format("Invalid object for %s.%s", t.name, field))
		end
		if proxy[tp].type ~= t then
			error(string.format("type[%s] mismatch for %s.%s", proxy[tp].type.name, t.name, field))
		end
	else
		obj = false
	end

	local old = self.obj[field]
	if old and not is_weak and old.owner == self.obj then
		old.owner = false
	end

	self.obj[field] = obj
end

local function type_proxy(obj, t)
	local p = setmetatable({} , proxy_mt )
	proxy[p] = { obj = obj, type = t }
	return p
end

local function new_object(self, ...)
	if not self.defined then
		error(string.format("%s is not defined", self.name))
	end
	local obj
	local id = object_id + 1
	object_id = id

	local n = #self.recycle
	if n > 0 then
		obj = self.recycle[n]
		self.recycle[n] = nil
		setmetatable(obj, nil)
		for k in pairs(obj) do
			if not self.keys[k] then
				obj[k] = nil
			end
		end
		obj._id = id
	else
		obj = { owner = false , _mark = not mark_flag, _id = id, _ref = false }
	end
	for k,v in pairs(self.field) do
		obj[k] = v
	end
	for k in pairs(self.ref) do
		obj[k] = false
	end
	for k in pairs(self.weak) do
		obj[k] = false
	end

	object_ids[id] = obj
	local tp = type_proxy(obj, self)
	objects[obj] = tp
	obj._ref = tp

	if self.ctor then
		-- If ctor raise error, collectgarbage would recycle obj
		self.ctor(obj, ...)
	end

	return obj
end

local function create_proxy(p, field)
	local self = proxy[p]
	local t = self.type.ref[field]
	if not t then
		error(string.format("Invalid field %s", field))
	end
	return function(...)
		local r = new_object(t, ...)
		link_proxy(p, field, r)
		r.owner = self.obj
		return r
	end
end

function typemethod:new(...)
	local obj = new_object(self, ...)
	root[obj] = true
	return obj
end

function class.type(obj)
	return proxy[obj._ref].type.name
end

function class.delete(obj)
	if not root[obj] then
		local t = obj._ref
		if t then
			local p = proxy[t]
			error(string.format("Already release object with type %s", p.type.name))
		end
		error(string.format("Release invalid object"))
	end
	root[obj] = nil
end

local function do_mark(obj)
	if obj._mark == mark_flag then
		return
	end
	obj._mark = mark_flag
	local p = proxy[obj._ref]
	if obj.owner then
		do_mark(obj.owner)
	end
	for field in pairs(p.type.ref) do
		local ref = obj[field]
		if ref then
			do_mark(ref)
		end
	end
end

local function release_obj(obj, p)
	local tp = proxy[p]
	objects[obj] = nil
	proxy[p] = nil
	local dtor = tp.type.dtor
	if dtor then
		dtor(obj)
	end
	table.insert(tp.type.recycle, obj)
	object_ids[obj._id] = nil
end

local function unref_weak(obj, p)
	local tp = proxy[p]
	local w = tp.type.weak
	for field in pairs(w) do
		local refobj = obj[field]
		if refobj and refobj._mark == mark_flag then
			obj[field] = false
		end
	end
end

function class.collectgarbage()
	for obj in pairs(root) do
		do_mark(obj)
	end
	mark_flag = not mark_flag
	for obj, p in pairs(objects) do
		if obj._mark == mark_flag then
			release_obj(obj, p)
		else
			unref_weak(obj, p)
		end
	end
end

function class.get(id)
	return object_ids[id]
end

function class.typename(obj)
	local t = proxy[obj._ref]
	return t and t.type.name
end

local function next_object(_, lastobj)
	local nextobj = next(root, lastobj)
	if nextobj == nil then
		return
	end
	return nextobj
end

local function next_type(c, lastobj)
	repeat
		lastobj = next(root, lastobj)
		if lastobj == nil then
			return
		end
	until proxy[lastobj._ref] == c
	return lastobj
end

function class.each(c)
	if c == nil then
		return next_object, nil, nil
	else
		if not c.defined then
			error(string.format("%s is not defined", c.typename))
		end
		return next_type, c, nil
	end
end

local function init()
	proxy_mt.__index = create_proxy
	proxy_mt.__newindex = link_proxy
	setmetatable(class, {
		__index = function(t, key)
			local tk = type(key)
			t[key] = setmetatable({
				name = key,
				defined = false,
				ref = {},
				field = {},
				weak = {},
				recycle = setmetatable({}, recycle_mt),
				keys = { owner = true, _mark = true, _id = true, _ref = true },
			}, typeclass)
			return t[key]
		end
	})
end

init()

return class
