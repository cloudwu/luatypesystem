local ts = require "typesystem"

ts.foo {
	_ctor = function(self, a)
		self.a = a
	end,
	_dtor = function(self)
		print("delete", self)
	end,
	a = 0,
	b = true,
	c = "hello",
	f = ts.foo,
	weak_g = ts.foo,
}

local f = ts.foo:new(1)
ts[f].f(2)

print("f = ", f)
print("f.f = ", f.f)

local ff = f.f

print("f.f.owner = ", ff.owner)

ts[f].f(3)

print("f.f = ", f.f, "ff.owner = ", ff.owner)


for obj in ts.each(ts.foo) do
	print("for", obj)
end

ts.collectgarbage()

ts[f].f = nil
print("clear f.f")

ts.collectgarbage()

ts.delete(f)
print("delete f")

ts.collectgarbage()

