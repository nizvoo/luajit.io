local C = require("cdef")
local ffi = require("ffi")
local tconcat = table.concat
local tinsert = table.insert

local pathx = {"/tmp/.shdict",1,1,1}
local kpathx = {1,1}
local dict_list = {}
local _M = {}
local shdict_mt = {__index = _M}

local function create_dict(name, size, user, group)
	if dict_list[name] then return dict_list[name] end
	pathx[2] = name
	pathx[3] = os.date("%s")
	pathx[4] = tostring(C.getpid())
	local path = tconcat(pathx, "_")
	print("mount " .. name .. ", " .. path)
	assert(C.mkdir(path, 448) == 0)
	assert(C.mount("tmpfs", path, "tmpfs", C.MS_MGC_VAL, "size=".. size) == 0)
	assert(C.chown(path, user, group) == 0)
	assert(C.chmod(path, 448) == 0)
	local dict = setmetatable({name=name, path=path}, shdict_mt)
	dict_list[name] = dict
	return dict
end

local function init(cfg)
	if cfg.lua_shared_dict then
		for k,v in pairs(cfg.lua_shared_dict) do
			create_dict(k,v,cfg.uid,cfg.gid)
		end
	end
end

local function fini()
	if dict_list then
		for name,dict in pairs(dict_list) do
			local path = dict.path
			print("unmount " .. name .. ", " .. path)
			C.umount(path)
			C.rmdir(path)
		end
		dict_list = nil
	end
end

local flock = ffi.new("struct flock")
flock.l_whence = C.SEEK_SET

local function lock_r(fd)
	flock.l_type = C.F_RDLCK
	assert(C.fcntl(fd, C.F_SETLKW, flock) == 0)
end

local function lock_w(fd)
	flock.l_type = C.F_WRLCK
	assert(C.fcntl(fd, C.F_SETLKW, flock) == 0)
end

local mode = ffi.new("mode_t", 384)
function _M.set(self, key, value)
	kpathx[1] = self.path
	kpathx[2] = key
	local path = tconcat(kpathx, "/")
	local fd = C.open(path, 65, mode)
	assert(fd > 0)
	lock_w(fd)
	local typ = type(value)
	if typ == "boolean" then
		typ = "b"
		value = tostring(value)
	elseif typ == "number" then
		typ = "n"
		value = tostring(value)
	elseif typ == "string" then
		typ = "s"
	end
	assert(C.write(fd, typ, 1) == 1)
	assert(C.write(fd, value, #value) == #value)
	assert(C.close(fd) == 0)
end

local RBUF_SIZE = 4096
local rbuf = ffi.new("char[?]", RBUF_SIZE)
function _M.get(self, key)
	kpathx[1] = self.path
	kpathx[2] = key
	local path = tconcat(kpathx, "/")
	local fd = C.open(path, 0)
	assert(fd > 0)
	lock_r(fd)
	assert(C.read(fd, rbuf, 1) == 1)
	local typ = ffi.string(rbuf,1)
	local t = {}
	while true do
		local len = C.read(fd, rbuf, RBUF_SIZE)
		if len > 0 then
			tinsert(t, ffi.string(rbuf, len))
		end
		if len < RBUF_SIZE then break end
	end
	assert(C.close(fd) == 0)
	local v = tconcat(t)
	if typ == "b" then
		v = (v == "true")
	elseif typ == "number" then
		v = tonumber(v)
	end
	return v
end

return {
	init = init,
	fini = fini,
	shared = dict_list
}