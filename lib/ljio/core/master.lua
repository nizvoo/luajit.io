-- Copyright (C) Jinhua Luo

local C = require("ljio.cdef")
local ffi = require("ffi")
local epoll = require("ljio.core.epoll")
local timer = require("ljio.core.timer")
local signal = require("ljio.core.signal")
local logging = require("ljio.core.logging")
local shdict = require("ljio.core.shdict")

local function master_parse_conf(cfg)
	cfg.user = cfg.user or "nobody"
	cfg.group = cfg.group or user
	local pw = C.getpwnam(cfg.user)
	if pw == nil then error("invalid user: " .. cfg.user) end
	cfg.uid = pw.pw_uid
	local grp = C.getgrnam(cfg.group)
	if grp == nil then error("invalid group: " .. cfg.group) end
	cfg.gid = grp.gr_gid

	shdict.init(cfg)

	logging.init(cfg)
	if cfg.log_import_print then logging.import_print() end

	if cfg.strict then require("ljio.core.strict") end
end

local function run_worker(cfg, init_worker)
	print("child pid=" .. C.getpid() .. " enter")

	if C.geteuid() == 0 then
		assert(C.setgid(cfg.gid) == 0)
		assert(C.initgroups(cfg.user, cfg.gid) == 0)
		assert(C.setuid(cfg.uid) == 0)
	end

	epoll.init()

	signal.init()

	timer.init()

	if cfg.working_directory then
		assert(C.chdir(cfg.working_directory) == 0)
	end

	init_worker()

	epoll.run()

	os.exit(0)
end

local M = {}

function M.run(cfg, parse_conf, init_worker)
	cfg.conf_file = arg[0]
	cfg.conf_prefix = string.match(arg[0], ".*/") or "./"
	if string.sub(cfg.conf_file, 1, 1) ~= "/" then
		local path_max = 4096
		local prefix = ffi.new("char[?]", path_max)
		assert(C.getcwd(prefix, path_max) == prefix)
		prefix = ffi.string(prefix)
		cfg.conf_file = prefix .. "/" .. cfg.conf_file
		cfg.conf_prefix = prefix .. "/" .. cfg.conf_prefix
		local f = io.open(cfg.conf_file)
		assert(f)
		f:close()
	end

	master_parse_conf(cfg)
	parse_conf(cfg)

	if cfg.daemon then
		assert(C.daemon(cfg.working_directory and 1 or 0, 0) == 0)
	end

	signal.ignore_signal(C.SIGPIPE)

	epoll.init()

	signal.init()

	local shutting_down = false
	local childs = {}
	local n_childs = 0

	signal.add_signal_handler(C.SIGHUP, function()
		local bak = M.run
		M.run = function(cfg, parse_conf)
			master_parse_conf(cfg)
			parse_conf(cfg)
		end
		local fn = loadfile(cfg.conf_file)
		local co = coroutine.create(fn, nil)
		local ret,err = coroutine.resume(co, cfg.conf_file)
		M.run = bak
		if err then
			print("reload error: " .. err)
			return
		end

		for pid in pairs(childs) do
			C.kill(pid, C.SIGQUIT)
		end

		for i= 1, cfg.worker_processes do
			local pid = C.fork()
			if pid > 0 then
				childs[pid] = 1
				n_childs = n_childs + 1
			end
			if pid == 0 then
				return run_worker(cfg, init_worker)
			end
		end
	end)

	signal.add_signal_handler(C.SIGCHLD, function(siginfo)
		print ("> child exit with pid=" .. siginfo.ssi_pid .. ", status=" .. siginfo.ssi_status)
		childs[siginfo.ssi_pid] = nil
		n_childs = n_childs - 1
		C.waitpid(siginfo.ssi_pid, nil, C.WNOHANG)
		local status = siginfo.ssi_status
		if status ~= C.SIGQUIT and status ~= C.SIGTERM and status ~= C.SIGINT and status ~= C.SIGSEGV then
			local pid = C.fork()
			if pid == 0 then
				run_worker(cfg, init_worker)
			end
			childs[pid] = 1
			n_childs = n_childs + 1
		end
		if shutting_down and n_childs == 0 then
			os.exit()
		end
	end)

	signal.add_signal_handler(C.SIGWINCH, function()
		for pid in pairs(childs) do
			C.kill(pid, C.SIGQUIT)
		end
	end)

	signal.add_signal_handler(C.SIGUSR2, function()
		local pid = C.fork()
		if pid == 0 then
			local args = {}
			for k,v in pairs(arg) do
				args[v] = k
				table.insert(args, v)
			end
			table.sort(args, function(a,b) return args[a] < args[b] end)
			local argv = ffi.new("void*[?]", #args + 1)
			for i=0,#args-1 do
				argv[i] = ffi.cast("void*", args[i+1])
			end
			local str = {"LUAJITIO="}
			for k,v in pairs(cfg.listening_fd) do
				table.insert(str, k)
			end
			local envp = ffi.new("void*[2]")
			str = table.concat(str, " ") .. "\0"
			envp[0] = ffi.cast("void*", str)
			return C.execvpe(args[1], argv, envp)
		end
	end)

	signal.add_signal_handler(C.SIGTERM, function()
		if n_childs == 0 then os.exit() end
		shutting_down = true
		for pid in pairs(childs) do
		print("SIGTERM",pid)
			C.kill(pid, C.SIGTERM)
		end
	end)

	signal.add_signal_handler(C.SIGQUIT, function()
		if n_childs == 0 then os.exit() end
		shutting_down = true
		for pid in pairs(childs) do
			C.kill(pid, C.SIGQUIT)
		end
	end)

	signal.add_signal_handler(C.SIGINT, function()
		if n_childs == 0 then os.exit() end
		shutting_down = true
		for pid in pairs(childs) do
			C.kill(pid, C.SIGINT)
		end
	end)

	timer.init()

	shdict.start_expire_timer()

	for i= 1, cfg.worker_processes do
		local pid = C.fork()
		if pid > 0 then
			childs[pid] = 1
			n_childs = n_childs + 1
		end
		if pid == 0 then
			run_worker(cfg, init_worker)
		end
	end

	epoll.run()
	print "> parent exit"
	os.exit(0)
end

return M
