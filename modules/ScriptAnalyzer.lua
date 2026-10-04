--[[
	Script Analyzer App Module

	Local static analysis of scripts, in four stages:
	  Extraction       - bytecode header, string/constant tables, imports, services, remotes, disassembly
	  Control Flow     - basic blocks, edges, dominator based loop detection, unreachable code
	  AST              - Luau parser (source text) with scope resolution
	  Code Generation  - lifted pseudo-code from bytecode, or regenerated source from the AST

	Two pipelines: getscriptbytecode (bytecode, decoded per the Luau Bytecode.h spec, Roblox's
	x227 opcode encoding is detected automatically) and source text (pasted or decompiled).
	Nothing is sent anywhere, everything runs in the client.
]]

-- Common Locals
local Main,Lib,Apps,Settings -- Main Containers
local Explorer, Properties, ScriptViewer, Notebook -- Major Apps
local API,RMD,env,service,plr,create,createSimple -- Main Locals

local function initDeps(data)
	Main = data.Main
	Lib = data.Lib
	Apps = data.Apps
	Settings = data.Settings

	API = data.API
	RMD = data.RMD
	env = data.env
	service = data.service
	plr = data.plr
	create = data.create
	createSimple = data.createSimple
end

local function initAfterMain()
	Explorer = Apps.Explorer
	Properties = Apps.Properties
	ScriptViewer = Apps.ScriptViewer
	Notebook = Apps.Notebook
end

local band, rshift = bit32.band, bit32.rshift
local sfmt, srep, concat, insert = string.format, string.rep, table.concat, table.insert

---------------------------------------------------------------------------------------------------
-- Core (no Roblox dependencies)
---------------------------------------------------------------------------------------------------
local Core = {}

-- Order must match LuauOpcode in Bytecode.h
local OPNAMES = {}
for name in ([[NOP BREAK LOADNIL LOADB LOADN LOADK MOVE GETGLOBAL SETGLOBAL GETUPVAL SETUPVAL CLOSEUPVALS
GETIMPORT GETTABLE SETTABLE GETTABLEKS SETTABLEKS GETTABLEN SETTABLEN NEWCLOSURE NAMECALL CALL RETURN JUMP
JUMPBACK JUMPIF JUMPIFNOT JUMPIFEQ JUMPIFLE JUMPIFLT JUMPIFNOTEQ JUMPIFNOTLE JUMPIFNOTLT ADD SUB MUL DIV MOD
POW ADDK SUBK MULK DIVK MODK POWK AND OR ANDK ORK CONCAT NOT MINUS LENGTH NEWTABLE DUPTABLE SETLIST FORNPREP
FORNLOOP FORGLOOP FORGPREP_INEXT FASTCALL3 FORGPREP_NEXT NATIVECALL GETVARARGS DUPCLOSURE PREPVARARGS LOADKX
JUMPX FASTCALL COVERAGE CAPTURE SUBRK DIVRK FASTCALL1 FASTCALL2 FASTCALL2K FORGPREP JUMPXEQKNIL JUMPXEQKB
JUMPXEQKN JUMPXEQKS IDIV IDIVK GETUDATAKS SETUDATAKS NAMECALLUDATA NEWCLASSMEMBER CALLFB CMPPROTO FASTPCALL
NEWCLASS]]):gmatch("%S+") do
	OPNAMES[#OPNAMES+1] = name
end
local OP = {}
for i,name in ipairs(OPNAMES) do OP[name] = i-1 end
Core.OPNAMES = OPNAMES

local function nameSet(str)
	local set = {}
	for name in str:gmatch("%S+") do set[OP[name]] = true end
	return set
end

local AUX_OPS = nameSet([[GETGLOBAL SETGLOBAL GETIMPORT GETTABLEKS SETTABLEKS NAMECALL JUMPIFEQ JUMPIFLE JUMPIFLT
	JUMPIFNOTEQ JUMPIFNOTLE JUMPIFNOTLT NEWTABLE SETLIST FORGLOOP LOADKX FASTCALL2 FASTCALL2K FASTCALL3 JUMPXEQKNIL
	JUMPXEQKB JUMPXEQKN JUMPXEQKS GETUDATAKS SETUDATAKS NAMECALLUDATA NEWCLASSMEMBER CALLFB CMPPROTO NEWCLASS]])
local JUMPD_OPS = nameSet([[JUMP JUMPIF JUMPIFNOT JUMPIFEQ JUMPIFLE JUMPIFLT JUMPIFNOTEQ JUMPIFNOTLE JUMPIFNOTLT
	FORNPREP FORNLOOP FORGPREP FORGLOOP FORGPREP_INEXT FORGPREP_NEXT JUMPBACK JUMPXEQKNIL JUMPXEQKB JUMPXEQKN
	JUMPXEQKS CMPPROTO]])
local FASTCALL_OPS = nameSet("FASTCALL FASTCALL1 FASTCALL2 FASTCALL2K FASTCALL3 FASTPCALL")
local NOFALL_OPS = nameSet("RETURN JUMP JUMPBACK JUMPX FORGPREP FORGPREP_NEXT FORGPREP_INEXT")

local BUILTINS, builtinId = {}, 0
for name in ([[NONE ASSERT MATH_ABS MATH_ACOS MATH_ASIN MATH_ATAN2 MATH_ATAN MATH_CEIL MATH_COSH MATH_COS MATH_DEG
MATH_EXP MATH_FLOOR MATH_FMOD MATH_FREXP MATH_LDEXP MATH_LOG10 MATH_LOG MATH_MAX MATH_MIN MATH_MODF MATH_POW MATH_RAD
MATH_SINH MATH_SIN MATH_SQRT MATH_TANH MATH_TAN BIT32_ARSHIFT BIT32_BAND BIT32_BNOT BIT32_BOR BIT32_BXOR BIT32_BTEST
BIT32_EXTRACT BIT32_LROTATE BIT32_LSHIFT BIT32_REPLACE BIT32_RROTATE BIT32_RSHIFT TYPE STRING_BYTE STRING_CHAR
STRING_LEN TYPEOF STRING_SUB MATH_CLAMP MATH_SIGN MATH_ROUND RAWSET RAWGET RAWEQUAL TABLE_INSERT TABLE_UNPACK VECTOR
BIT32_COUNTLZ BIT32_COUNTRZ SELECT_VARARG RAWLEN BIT32_EXTRACTK GETMETATABLE SETMETATABLE TONUMBER TOSTRING
BIT32_BYTESWAP BUFFER_READI8 BUFFER_READU8 BUFFER_WRITEU8 BUFFER_READI16 BUFFER_READU16 BUFFER_WRITEU16
BUFFER_READI32 BUFFER_READU32 BUFFER_WRITEU32 BUFFER_READF32 BUFFER_WRITEF32 BUFFER_READF64 BUFFER_WRITEF64
VECTOR_MAGNITUDE VECTOR_NORMALIZE VECTOR_CROSS VECTOR_DOT VECTOR_FLOOR VECTOR_CEIL VECTOR_ABS VECTOR_SIGN
VECTOR_CLAMP VECTOR_MIN VECTOR_MAX MATH_LERP VECTOR_LERP MATH_ISNAN MATH_ISINF MATH_ISFINITE]]):gmatch("%S+") do
	local lib, fn = name:match("^(%u+%d*)_(.+)$")
	if lib and (lib == "MATH" or lib == "BIT32" or lib == "STRING" or lib == "TABLE" or lib == "BUFFER" or lib == "VECTOR") then
		name = lib:lower().."."..fn:lower()
	else
		name = name:lower()
	end
	BUILTINS[builtinId] = name
	builtinId += 1
end

local CAPTURE_TYPES = {[0] = "VAL", "REF", "UPVAL"}
local PROTO_FLAGS = {{1,"native-module"},{2,"native-cold"},{4,"native-function"},{8,"inlinable"},{16,"uses-export"}}

local function signed(v, bits)
	local lim = 2^(bits-1)
	if v >= lim then return v - 2^bits end
	return v
end

local function isIdent(s)
	return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil
end

local function quote(s)
	s = s:gsub("[%c\"\\]", function(c)
		if c == "\n" then return "\\n" elseif c == "\t" then return "\\t" elseif c == "\r" then return "\\r"
		elseif c == "\"" then return "\\\"" elseif c == "\\" then return "\\\\" end
		return sfmt("\\%03d", c:byte())
	end)
	return "\""..s.."\""
end
Core.Quote = quote

local function fmtNumber(n)
	if n ~= n then return "0/0" end
	if n == math.huge then return "math.huge" elseif n == -math.huge then return "-math.huge" end
	if n == math.floor(n) and math.abs(n) < 2^53 then return sfmt("%d", n) end
	local s = sfmt("%.17g", n)
	for prec = 1, 17 do
		local t = sfmt("%."..prec.."g", n)
		if tonumber(t) == n then s = t break end
	end
	return s
end

---------------------------------------------------------------------------------------------------
-- Bytecode deserializer
---------------------------------------------------------------------------------------------------
local function newReader(data)
	local r = {pos = 1}
	local len = #data
	local function need(n)
		if r.pos + n - 1 > len then error(sfmt("unexpected end of bytecode at offset %d", r.pos - 1), 0) end
	end
	function r.u8()
		need(1)
		local b = data:byte(r.pos)
		r.pos += 1
		return b
	end
	function r.unpack(fmt, size)
		need(size)
		local v = string.unpack(fmt, data, r.pos)
		r.pos += size
		return v
	end
	function r.u32() return r.unpack("<I4", 4) end
	function r.i32() return r.unpack("<i4", 4) end
	function r.f32() return r.unpack("<f", 4) end
	function r.f64() return r.unpack("<d", 8) end
	function r.varint()
		local result, shift = 0, 0
		repeat
			local b = r.u8()
			result += band(b, 127) * 2^shift
			shift += 7
		until b < 128
		return result
	end
	function r.bytes(n)
		need(n)
		local s = data:sub(r.pos, r.pos + n - 1)
		r.pos += n
		return s
	end
	return r
end

Core.Deserialize = function(data)
	if type(data) ~= "string" or #data == 0 then error("empty bytecode", 0) end
	local r = newReader(data)
	local chunk = {Size = #data, Strings = {}, UserdataTypes = {}, Protos = {}}

	local version = r.u8()
	chunk.Version = version
	if version == 0 then
		chunk.CompileError = data:sub(2)
		return chunk
	end
	if (version < 3 or version > 14) and version ~= 100 then
		error(sfmt("unsupported bytecode version %d (supported: 3-14)", version), 0)
	end

	local typesVersion = 0
	if version >= 4 then typesVersion = r.u8() end
	chunk.TypesVersion = typesVersion

	local strings = chunk.Strings
	for i = 1, r.varint() do
		strings[i] = r.bytes(r.varint())
	end
	local function readString()
		local id = r.varint()
		if id == 0 then return nil end
		return strings[id]
	end

	if typesVersion == 3 then
		local index = r.u8()
		while index ~= 0 do
			insert(chunk.UserdataTypes, {Index = index, Name = readString()})
			index = r.u8()
		end
	end

	for protoId = 0, r.varint() - 1 do
		local p = {Id = protoId, Code = {}, K = {}, Children = {}, Locals = {}, Upvalues = {}}
		local protoSize, protoStart
		if version >= 12 then
			protoSize = r.varint()
			protoStart = r.pos
		end

		p.MaxStack = r.u8()
		p.NumParams = r.u8()
		p.NumUpvalues = r.u8()
		p.IsVararg = r.u8() ~= 0
		p.Flags = 0
		if version >= 4 then
			p.Flags = r.u8()
			local typeSize = r.varint()
			if typeSize > 0 then p.TypeInfo = r.bytes(typeSize) end
		end

		local code = p.Code
		for j = 1, r.varint() do code[j] = r.u32() end

		local k = p.K
		for j = 1, r.varint() do
			local tag = r.u8()
			local c = {Tag = tag}
			if tag == 0 then
				c.Type = "nil"
			elseif tag == 1 then
				c.Type, c.Value = "boolean", r.u8() ~= 0
			elseif tag == 2 then
				c.Type, c.Value = "number", r.f64()
			elseif tag == 3 then
				c.Type, c.Value = "string", readString()
			elseif tag == 4 then
				c.Type, c.Value = "import", r.u32()
			elseif tag == 5 then
				c.Type, c.Keys = "table", {}
				for i = 1, r.varint() do c.Keys[i] = r.varint() end
			elseif tag == 6 then
				c.Type, c.Value = "closure", r.varint()
			elseif tag == 7 then
				c.Type, c.Value = "vector", {r.f32(), r.f32(), r.f32(), r.f32()}
			elseif tag == 8 then
				c.Type, c.Keys, c.Values = "table", {}, {}
				for i = 1, r.varint() do
					c.Keys[i] = r.varint()
					c.Values[i] = r.i32()
				end
			elseif tag == 9 then
				local negative = r.u8() ~= 0
				local magnitude = r.varint()
				c.Type, c.Value = "integer", negative and -magnitude or magnitude
			elseif tag == 10 then
				c.Type, c.Value = "classshape", r.varint()
				local members = r.varint() + r.varint()
				c.Members = {}
				for i = 1, members do c.Members[i] = r.varint() end
			elseif tag == 11 then
				c.Type, c.Value = "vector", {r.f64(), r.f64(), r.f64(), r.f64()}
			else
				error(sfmt("unknown constant tag %d in proto %d", tag, protoId), 0)
			end
			k[j] = c
		end

		for j = 1, r.varint() do p.Children[j] = r.varint() end

		p.LineDefined = r.varint()
		p.DebugName = readString()

		if r.u8() ~= 0 then
			local gap = r.u8()
			local sizecode = #code
			local intervals = sizecode > 0 and (rshift(sizecode - 1, gap) + 1) or 0
			local lineinfo, abs = {}, {}
			local last = 0
			for j = 1, sizecode do
				last = (last + r.u8()) % 256
				lineinfo[j] = last
			end
			local lastLine = 0
			for j = 1, intervals do
				lastLine += r.i32()
				abs[j] = lastLine
			end
			p.Lines = {}
			for pc = 0, sizecode - 1 do
				p.Lines[pc] = abs[rshift(pc, gap) + 1] + lineinfo[pc + 1]
			end
		end

		if r.u8() ~= 0 then
			for j = 1, r.varint() do
				p.Locals[j] = {Name = readString(), StartPc = r.varint(), EndPc = r.varint(), Reg = r.u8()}
			end
			for j = 1, r.varint() do p.Upvalues[j] = readString() end
		end

		if version >= 11 then
			for j = 1, r.varint() do
				r.u8()
				r.varint()
			end
		end
		if version >= 12 then
			if band(p.Flags, 8) ~= 0 then p.Cost = r.varint() end
			r.pos = protoStart + protoSize
		end

		chunk.Protos[protoId] = p
		chunk.ProtoCount = protoId + 1
	end

	chunk.MainId = r.varint()
	chunk.Trailing = #data - r.pos + 1
	return chunk
end

-- Roblox ships bytecode with every opcode byte multiplied by 227 (mod 256); 203 is its inverse
local function makeDecoder(encoded)
	if encoded then
		return function(insn) return band(band(insn, 255) * 203, 255) end
	end
	return function(insn) return band(insn, 255) end
end

local function walkValid(p, decodeOp)
	local code, pc, n = p.Code, 0, #p.Code
	while pc < n do
		local op = decodeOp(code[pc + 1])
		if op >= #OPNAMES then return false end
		pc += AUX_OPS[op] and 2 or 1
	end
	return pc == n
end

Core.DetectEncoding = function(chunk)
	local scores = {}
	for _, encoded in ipairs({false, true}) do
		local decodeOp, score = makeDecoder(encoded), 0
		for id = 0, (chunk.ProtoCount or 0) - 1 do
			if walkValid(chunk.Protos[id], decodeOp) then score += 1 end
		end
		scores[encoded] = score
	end
	-- The main proto is always vararg and starts with PREPVARARGS, best single tell
	local main = chunk.Protos[chunk.MainId]
	local first = main and main.Code[1]
	if first and scores[true] == scores[false] then
		if makeDecoder(true)(first) == OP.PREPVARARGS and makeDecoder(false)(first) ~= OP.PREPVARARGS then return true end
		return false
	end
	return scores[true] > scores[false]
end

-- Decodes every instruction of every proto: proto.Insns[pc] (pc is 0 based, AUX words skipped)
Core.Decode = function(chunk, encoded)
	if encoded == nil then encoded = Core.DetectEncoding(chunk) end
	chunk.Encoded = encoded
	local decodeOp = makeDecoder(encoded)
	for id = 0, (chunk.ProtoCount or 0) - 1 do
		local p = chunk.Protos[id]
		local code, insns, order = p.Code, {}, {}
		local pc, n = 0, #p.Code
		while pc < n do
			local word = code[pc + 1]
			local op = decodeOp(word)
			local i = {
				Pc = pc, Op = op, Name = OPNAMES[op + 1] or ("OP_"..op),
				A = band(rshift(word, 8), 255), B = band(rshift(word, 16), 255), C = band(rshift(word, 24), 255),
				D = signed(rshift(word, 16), 16), E = signed(rshift(word, 8), 24),
				Len = AUX_OPS[op] and 2 or 1
			}
			if i.Len == 2 then i.Aux = code[pc + 2] or 0 end
			if JUMPD_OPS[op] then
				i.Target = pc + i.D + 1
			elseif op == OP.JUMPX then
				i.Target = pc + i.E + 1
			elseif op == OP.LOADB and i.C ~= 0 then
				i.Target = pc + i.C + 1
			elseif FASTCALL_OPS[op] then
				i.FastTarget = pc + i.C + 2
			end
			i.Falls = not NOFALL_OPS[op]
			i.Line = p.Lines and p.Lines[pc]
			insns[pc] = i
			order[#order+1] = i
			pc += i.Len
		end
		p.Insns, p.Order = insns, order
	end
	return chunk
end

local function importPath(p, id)
	local count = rshift(id, 30)
	local parts = {}
	for j = 1, count do
		local idx = band(rshift(id, 30 - j*10), 1023)
		local c = p.K[idx + 1]
		parts[j] = c and c.Value or ("?"..idx)
	end
	return concat(parts, ".")
end

local function constText(chunk, p, idx, depth)
	local c = p.K[idx + 1]
	if not c then return "K"..idx.."?" end
	local t = c.Type
	if t == "nil" then return "nil"
	elseif t == "boolean" then return tostring(c.Value)
	elseif t == "number" then return fmtNumber(c.Value)
	elseif t == "integer" then return fmtNumber(c.Value).."i"
	elseif t == "string" then return c.Value and quote(c.Value) or "nil"
	elseif t == "import" then return importPath(p, c.Value)
	elseif t == "vector" then return sfmt("vector(%s, %s, %s)", fmtNumber(c.Value[1]), fmtNumber(c.Value[2]), fmtNumber(c.Value[3]))
	elseif t == "closure" then return "proto_"..c.Value
	elseif t == "classshape" then return "class "..constText(chunk, p, c.Value, 1)
	elseif t == "table" then
		if (depth or 0) > 0 then return "{...}" end
		local parts = {}
		for j, key in ipairs(c.Keys) do
			local kc = p.K[key + 1]
			local keyText = (kc and kc.Type == "string" and isIdent(kc.Value)) and kc.Value or ("["..constText(chunk, p, key, 1).."]")
			local val = c.Values and c.Values[j]
			parts[j] = keyText.." = "..((val and val >= 0) and constText(chunk, p, val, 1) or "_")
		end
		return "{"..concat(parts, ", ").."}"
	end
	return "?"
end
Core.ConstText = constText

local function protoLabel(chunk, id)
	local p = chunk.Protos[id]
	if not p then return "proto_"..tostring(id) end
	local name = p.DebugName or (id == chunk.MainId and "main" or "anonymous")
	return sfmt("#%d %s", id, name)
end

-- Debug name of a register at pc, when the script still has local debug info
local function regName(p, reg, pc)
	for _, l in ipairs(p.Locals) do
		if l.Reg == reg and pc >= l.StartPc and pc < l.EndPc and l.Name then return l.Name end
	end
	return nil
end

local function kString(p, idx)
	local c = p.K[idx + 1]
	return c and c.Type == "string" and c.Value or nil
end

-- Operands + annotation for the disassembly listing
local function disasmInsn(chunk, p, i)
	local name, A, B, C, D, aux = i.Name, i.A, i.B, i.C, i.D, i.Aux
	local R = function(r) return "R"..r end
	local ops, note = "", nil
	if name == "LOADNIL" or name == "CLOSEUPVALS" or name == "PREPVARARGS" then ops = R(A)
	elseif name == "LOADB" then ops = sfmt("R%d %d %d", A, B, C) note = B ~= 0 and "true" or "false"
	elseif name == "LOADN" then ops = sfmt("R%d %d", A, D)
	elseif name == "LOADK" then ops = sfmt("R%d K%d", A, D) note = constText(chunk, p, D)
	elseif name == "LOADKX" then ops = sfmt("R%d K%d", A, aux) note = constText(chunk, p, aux)
	elseif name == "MOVE" or name == "NOT" or name == "MINUS" or name == "LENGTH" then ops = sfmt("R%d R%d", A, B)
	elseif name == "GETGLOBAL" or name == "SETGLOBAL" then ops = sfmt("R%d K%d", A, aux) note = constText(chunk, p, aux)
	elseif name == "GETUPVAL" or name == "SETUPVAL" then ops = sfmt("R%d U%d", A, B) note = p.Upvalues[B + 1]
	elseif name == "GETIMPORT" then ops = sfmt("R%d K%d", A, D) note = importPath(p, aux)
	elseif name == "GETTABLE" or name == "SETTABLE" then ops = sfmt("R%d R%d R%d", A, B, C)
	elseif name == "GETTABLEKS" or name == "SETTABLEKS" or name == "NAMECALL" then ops = sfmt("R%d R%d K%d", A, B, aux) note = constText(chunk, p, aux)
	elseif name == "GETUDATAKS" or name == "SETUDATAKS" or name == "NAMECALLUDATA" then ops = sfmt("R%d R%d K%d", A, B, band(aux, 0xffff)) note = constText(chunk, p, band(aux, 0xffff))
	elseif name == "GETTABLEN" or name == "SETTABLEN" then ops = sfmt("R%d R%d %d", A, B, C + 1)
	elseif name == "NEWCLOSURE" then ops = sfmt("R%d P%d", A, D) note = protoLabel(chunk, p.Children[D + 1])
	elseif name == "DUPCLOSURE" then ops = sfmt("R%d K%d", A, D) local c = p.K[D + 1] note = c and c.Type == "closure" and protoLabel(chunk, c.Value) or nil
	elseif name == "CALL" or name == "CALLFB" then ops = sfmt("R%d %d %d", A, B - 1, C - 1)
	elseif name == "RETURN" then ops = sfmt("R%d %d", A, B - 1)
	elseif name == "GETVARARGS" then ops = sfmt("R%d %d", A, B - 1)
	elseif name == "JUMP" or name == "JUMPBACK" or name == "JUMPX" then ops = "L"..i.Target
	elseif name == "JUMPIF" or name == "JUMPIFNOT" then ops = sfmt("R%d L%d", A, i.Target)
	elseif name:match("^JUMPIF") then ops = sfmt("R%d R%d L%d", A, aux, i.Target)
	elseif name == "JUMPXEQKNIL" then ops = sfmt("R%d L%d", A, i.Target) note = (rshift(aux, 31) ~= 0 and "~= " or "== ").."nil"
	elseif name == "JUMPXEQKB" then ops = sfmt("R%d %d L%d", A, band(aux, 1), i.Target) note = (rshift(aux, 31) ~= 0 and "~= " or "== ")..tostring(band(aux, 1) ~= 0)
	elseif name == "JUMPXEQKN" or name == "JUMPXEQKS" then ops = sfmt("R%d K%d L%d", A, band(aux, 0xffffff), i.Target) note = (rshift(aux, 31) ~= 0 and "~= " or "== ")..constText(chunk, p, band(aux, 0xffffff))
	elseif name == "SUBRK" or name == "DIVRK" then ops = sfmt("R%d K%d R%d", A, B, C) note = constText(chunk, p, B)
	elseif name:match("K$") and (name:match("^ADD") or name:match("^SUB") or name:match("^MUL") or name:match("^DIV") or name:match("^MOD") or name:match("^POW") or name:match("^IDIV") or name == "ANDK" or name == "ORK") then
		ops = sfmt("R%d R%d K%d", A, B, C) note = constText(chunk, p, C)
	elseif name == "CONCAT" or name == "ADD" or name == "SUB" or name == "MUL" or name == "DIV" or name == "MOD" or name == "POW" or name == "IDIV" or name == "AND" or name == "OR" then
		ops = sfmt("R%d R%d R%d", A, B, C)
	elseif name == "NEWTABLE" then ops = sfmt("R%d %d %d", A, B, aux)
	elseif name == "DUPTABLE" then ops = sfmt("R%d K%d", A, D) note = constText(chunk, p, D)
	elseif name == "SETLIST" then ops = sfmt("R%d R%d %d [%d]", A, B, C - 1, aux)
	elseif name == "FORNPREP" or name == "FORNLOOP" or name == "FORGPREP" or name == "FORGPREP_NEXT" or name == "FORGPREP_INEXT" then ops = sfmt("R%d L%d", A, i.Target)
	elseif name == "FORGLOOP" then ops = sfmt("R%d L%d %d", A, i.Target, band(aux, 255)) note = rshift(aux, 31) ~= 0 and "ipairs" or nil
	elseif name == "CAPTURE" then ops = sfmt("%s %s%d", CAPTURE_TYPES[A] or tostring(A), A == 2 and "U" or "R", B)
	elseif FASTCALL_OPS[i.Op] then
		local fname = BUILTINS[A] or ("builtin_"..A)
		if name == "FASTPCALL" then fname = A == 0 and "pcall" or "xpcall" end
		if name == "FASTCALL" then ops = sfmt("%d L%d", A, i.FastTarget)
		elseif name == "FASTCALL2" then ops = sfmt("%d R%d R%d L%d", A, B, band(aux, 255), i.FastTarget)
		elseif name == "FASTCALL2K" then ops = sfmt("%d R%d K%d L%d", A, B, aux, i.FastTarget) fname = fname..", "..constText(chunk, p, aux)
		elseif name == "FASTCALL3" then ops = sfmt("%d R%d R%d R%d L%d", A, B, band(aux, 255), band(rshift(aux, 8), 255), i.FastTarget)
		else ops = sfmt("%d R%d L%d", A, B, i.FastTarget) end
		note = fname
	elseif name == "COVERAGE" then ops = tostring(i.E)
	elseif i.Aux then ops = sfmt("%d %d %d [%d]", A, B, C, aux)
	elseif i.Target then ops = sfmt("R%d L%d", A, i.Target)
	else ops = sfmt("%d %d %d", A, B, C) end
	return ops, note
end

local function protoHeader(chunk, p)
	local flags = {}
	for _, f in ipairs(PROTO_FLAGS) do if band(p.Flags, f[1]) ~= 0 then flags[#flags+1] = f[2] end end
	return sfmt("function %s  (line %d)  params=%d%s upvalues=%d stack=%d instructions=%d constants=%d%s",
		protoLabel(chunk, p.Id), p.LineDefined, p.NumParams, p.IsVararg and "+..." or "", p.NumUpvalues, p.MaxStack,
		#p.Order, #p.K, #flags > 0 and (" flags="..concat(flags, ",")) or "")
end

Core.Disassemble = function(chunk, p, out, indent)
	indent = indent or "\t"
	for _, i in ipairs(p.Order) do
		local ops, note = disasmInsn(chunk, p, i)
		local line = sfmt("%s%4d %s %-13s %s", indent, i.Pc, i.Line and sfmt("%5s", ":"..i.Line) or "     ", i.Name, ops)
		if note then line = line.."  ; "..note end
		out[#out+1] = line
	end
end

-- Walks every decoded instruction once and pulls out the interesting bits
local INTERESTING_METHODS = {
	FireServer = "remote", InvokeServer = "remote", FireClient = "remote", FireAllClients = "remote", InvokeClient = "remote",
	Fire = "bindable", Invoke = "bindable",
	HttpGet = "http", HttpGetAsync = "http", HttpPost = "http", HttpPostAsync = "http", RequestAsync = "http", GetAsync = "http", PostAsync = "http",
	Kick = "kick", LoadAsset = "asset", GetObjects = "asset", Teleport = "teleport", TeleportAsync = "teleport", TeleportToPlaceInstance = "teleport",
}

local function findLoadedString(p, fromPc, toPc, reg)
	for pc = toPc, math.max(fromPc, 0), -1 do
		local i = p.Insns[pc]
		if i and i.A == reg then
			-- nearest instruction touching the register decides, anything but a string load means unknown
			if i.Name == "LOADK" then return kString(p, i.D) end
			if i.Name == "LOADKX" then return kString(p, i.Aux) end
			return nil
		end
	end
	return nil
end

local function nextCall(p, pc)
	for _, i in ipairs(p.Order) do
		if i.Pc > pc and (i.Name == "CALL" or i.Name == "CALLFB") then return i end
	end
	return nil
end

Core.ExtractBytecode = function(chunk)
	local imports, globals, services, calls, urls, functions = {}, {}, {}, {}, {}, {}
	local function bump(t, k) t[k] = (t[k] or 0) + 1 end
	for id = 0, chunk.ProtoCount - 1 do
		local p = chunk.Protos[id]
		functions[#functions+1] = p
		for _, i in ipairs(p.Order) do
			local n = i.Name
			if n == "GETIMPORT" then bump(imports, importPath(p, i.Aux))
			elseif n == "GETGLOBAL" then bump(globals, (kString(p, i.Aux) or "?").." (get)")
			elseif n == "SETGLOBAL" then bump(globals, (kString(p, i.Aux) or "?").." (set)")
			elseif n == "NAMECALL" or n == "NAMECALLUDATA" then
				local method = kString(p, n == "NAMECALL" and i.Aux or band(i.Aux, 0xffff))
				local call = nextCall(p, i.Pc)
				-- the argument is usually loaded right before the NAMECALL, so look back a little
				local arg = call and findLoadedString(p, i.Pc - 32, call.Pc - 1, i.A + 2)
				if method == "GetService" or method == "FindService" then
					if arg then bump(services, arg) end
				elseif method and INTERESTING_METHODS[method] then
					calls[#calls+1] = sfmt("%-8s :%s(%s)  in %s at pc %d%s", INTERESTING_METHODS[method], method, arg and quote(arg) or "...",
						protoLabel(chunk, id), i.Pc, i.Line and (" line "..i.Line) or "")
				end
			end
		end
	end
	for _, s in ipairs(chunk.Strings) do
		for url in s:gmatch("[%w]+://[%w%-%._~:/%?#%[%]@!%$&'%(%)%*%+,;=%%]+") do urls[#urls+1] = url end
		for id in s:gmatch("rbxassetid://%d+") do urls[#urls+1] = id end
	end
	return {Imports = imports, Globals = globals, Services = services, Calls = calls, Urls = urls, Functions = functions}
end

local function sortedCounts(t)
	local list = {}
	for k, v in pairs(t) do list[#list+1] = {k, v} end
	table.sort(list, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
	return list
end

Core.ReportExtraction = function(chunk)
	local out = {}
	local function add(s) out[#out+1] = s end
	add("-- Script Analyzer :: Extraction (bytecode)")
	if chunk.CompileError then
		add("-- The bytecode holds a compile error instead of code:")
		add("--[[\n"..chunk.CompileError.."\n]]")
		return concat(out, "\n")
	end
	add(sfmt("-- Size: %d bytes | Bytecode version %d | Types version %d | Opcode encoding: %s", chunk.Size, chunk.Version,
		chunk.TypesVersion, chunk.Encoded and "Roblox (op * 227)" or "standard"))
	add(sfmt("-- Functions: %d (main #%d) | Strings: %d%s", chunk.ProtoCount, chunk.MainId, #chunk.Strings,
		chunk.Trailing ~= 0 and sfmt(" | %d trailing bytes", chunk.Trailing) or ""))
	local hasDebug = false
	for id = 0, chunk.ProtoCount - 1 do if #chunk.Protos[id].Locals > 0 then hasDebug = true break end end
	add("-- Debug info: "..(hasDebug and "local names present" or "stripped (register names only)"))
	add("")

	local ex = Core.ExtractBytecode(chunk)
	local function section(title, list, fmt)
		add("--[[ "..title.." ("..#list..") ]]")
		if #list == 0 then add("\t(none)") end
		for _, v in ipairs(list) do add("\t"..fmt(v)) end
		add("")
	end
	section("Services", sortedCounts(ex.Services), function(v) return sfmt("%-28s x%d", v[1], v[2]) end)
	section("Imports (globals resolved at load)", sortedCounts(ex.Imports), function(v) return sfmt("%-28s x%d", v[1], v[2]) end)
	section("Dynamic globals", sortedCounts(ex.Globals), function(v) return sfmt("%-28s x%d", v[1], v[2]) end)
	section("Remote / network / http calls", ex.Calls, function(v) return v end)
	section("URLs and asset ids", ex.Urls, function(v) return v end)
	if #chunk.UserdataTypes > 0 then
		section("Userdata types", chunk.UserdataTypes, function(v) return sfmt("%d = %s", v.Index, tostring(v.Name)) end)
	end
	section("Functions", ex.Functions, function(p) return protoHeader(chunk, p):gsub("^function ", "") end)

	add("--[[ String table ("..#chunk.Strings..") ]]")
	for idx, s in ipairs(chunk.Strings) do add(sfmt("\tS%-4d %s", idx, quote(#s > 200 and (s:sub(1, 200).."...") or s))) end
	add("")

	add("--[[ Disassembly ]]")
	for id = 0, chunk.ProtoCount - 1 do
		local p = chunk.Protos[id]
		add("")
		add(protoHeader(chunk, p))
		if #p.K > 0 then
			local ks = {}
			for idx = 0, #p.K - 1 do ks[#ks+1] = sfmt("K%d=%s", idx, constText(chunk, p, idx)) end
			add("\t-- constants: "..concat(ks, "  "))
		end
		if #p.Upvalues > 0 then add("\t-- upvalues: "..concat(p.Upvalues, ", ")) end
		if #p.Children > 0 then
			local cs = {}
			for j, c in ipairs(p.Children) do cs[j] = sfmt("P%d=%s", j - 1, protoLabel(chunk, c)) end
			add("\t-- children: "..concat(cs, ", "))
		end
		Core.Disassemble(chunk, p, out)
	end
	return concat(out, "\n")
end

---------------------------------------------------------------------------------------------------
-- Control flow graphs (shared by bytecode and source pipelines)
---------------------------------------------------------------------------------------------------
local function newGraph(name)
	return {Name = name, Blocks = {}}
end

local function addBlock(g, label)
	local b = {Id = #g.Blocks, Lines = {}, Succ = {}, Pred = {}, Label = label}
	g.Blocks[#g.Blocks+1] = b
	return b
end

local function addEdge(from, to, kind)
	if not from or not to then return end
	for _, e in ipairs(from.Succ) do if e.To == to then return end end
	from.Succ[#from.Succ+1] = {To = to, Kind = kind}
	to.Pred[#to.Pred+1] = from
end

-- Reachability, dominators (iterative, reverse postorder), natural loops from back edges
local function analyzeGraph(g)
	local blocks = g.Blocks
	local entry = blocks[1]
	local order, seen = {}, {}
	local function dfs(b)
		seen[b] = true
		for _, e in ipairs(b.Succ) do if not seen[e.To] then dfs(e.To) end end
		order[#order+1] = b
	end
	if entry then dfs(entry) end
	local rpo = {}
	for j = #order, 1, -1 do rpo[#rpo+1] = order[j] end
	local index = {}
	for j, b in ipairs(rpo) do index[b] = j end

	local idom = {}
	if entry then idom[entry] = entry end
	local function intersect(a, b)
		while a ~= b do
			while index[a] > index[b] do a = idom[a] end
			while index[b] > index[a] do b = idom[b] end
		end
		return a
	end
	local changed = true
	while changed do
		changed = false
		for j = 2, #rpo do
			local b = rpo[j]
			local new
			for _, p in ipairs(b.Pred) do
				if idom[p] and index[p] then new = new and intersect(p, new) or p end
			end
			if new and idom[b] ~= new then idom[b] = new changed = true end
		end
	end
	local function dominates(a, b)
		while true do
			if a == b then return true end
			local up = idom[b]
			if not up or up == b then return false end
			b = up
		end
	end

	local loops, edges = {}, 0
	for _, b in ipairs(blocks) do
		b.Reachable = seen[b] or false
		for _, e in ipairs(b.Succ) do
			edges += 1
			if seen[b] and dominates(e.To, b) then
				e.Back = true
				local body, stack = {[e.To] = true}, {b}
				while #stack > 0 do
					local x = table.remove(stack)
					if not body[x] then
						body[x] = true
						for _, p in ipairs(x.Pred) do stack[#stack+1] = p end
					end
				end
				local ids = {}
				for x in pairs(body) do ids[#ids+1] = x.Id end
				table.sort(ids)
				loops[#loops+1] = {Header = e.To, Latch = b, Blocks = ids}
			end
		end
	end
	local reachable = 0
	for _ in pairs(seen) do reachable += 1 end
	g.Loops, g.EdgeCount, g.ReachableCount = loops, edges, reachable
	g.Complexity = edges - reachable + 2
	g.Idom = idom
	return g
end

local function renderGraph(g, out)
	out[#out+1] = sfmt("%s\n\t-- blocks=%d edges=%d loops=%d cyclomatic=%d%s", g.Name, #g.Blocks, g.EdgeCount, #g.Loops,
		math.max(g.Complexity, 1), g.ReachableCount < #g.Blocks and sfmt(" unreachable=%d", #g.Blocks - g.ReachableCount) or "")
	for _, b in ipairs(g.Blocks) do
		local succ = {}
		for _, e in ipairs(b.Succ) do
			succ[#succ+1] = "B"..e.To.Id..(e.Kind and ("("..e.Kind..")") or "")..(e.Back and "*" or "")
		end
		local pred = {}
		for _, p in ipairs(b.Pred) do pred[#pred+1] = "B"..p.Id end
		local idom = g.Idom[b]
		out[#out+1] = sfmt("\tB%d%s%s  -> %s   <- %s%s", b.Id, b.Label and (" "..b.Label) or "",
			b.Reachable and "" or " [UNREACHABLE]", #succ > 0 and concat(succ, ", ") or "exit",
			#pred > 0 and concat(pred, ", ") or "entry", (idom and idom ~= b) and ("   idom B"..idom.Id) or "")
		for _, l in ipairs(b.Lines) do out[#out+1] = "\t\t"..l end
	end
	for _, l in ipairs(g.Loops) do
		local idList = {}
		for _, id in ipairs(l.Blocks) do idList[#idList+1] = "B"..id end
		out[#out+1] = sfmt("\t-- loop%s: header B%d, latch B%d, body {%s}", l.Kind and (" ("..l.Kind..")") or "", l.Header.Id, l.Latch.Id, concat(idList, ", "))
	end
	out[#out+1] = ""
end

Core.BuildProtoGraph = function(chunk, p)
	local g = newGraph(protoHeader(chunk, p))
	local leaders = {[0] = true}
	for _, i in ipairs(p.Order) do
		if i.Target then
			leaders[i.Target] = true
			leaders[i.Pc + i.Len] = true
		elseif not i.Falls then
			leaders[i.Pc + i.Len] = true
		end
	end
	local byPc, cur = {}, nil
	for _, i in ipairs(p.Order) do
		if leaders[i.Pc] or not cur then
			cur = addBlock(g, sfmt("[pc %d]", i.Pc))
			byPc[i.Pc] = cur
		end
		cur.Last = i
		cur.Insns = cur.Insns or {}
		cur.Insns[#cur.Insns+1] = i
	end
	for idx, b in ipairs(g.Blocks) do
		local i = b.Last
		local nextBlock = g.Blocks[idx + 1]
		if i.Target and byPc[i.Target] then
			local kind = i.Falls and "jump" or nil
			if i.Name == "FORNPREP" then kind = "skip" elseif i.Name == "FORNLOOP" or i.Name == "FORGLOOP" then kind = "loop" end
			addEdge(b, byPc[i.Target], kind)
		end
		if i.Falls and nextBlock then addEdge(b, nextBlock, i.Target and "next" or nil) end
		local first, last = b.Insns[1].Pc, i.Pc
		b.Label = first == last and sfmt("[pc %d]", first) or sfmt("[pc %d-%d]", first, last)
		for _, ins in ipairs(b.Insns) do
			local ops, note = disasmInsn(chunk, p, ins)
			b.Lines[#b.Lines+1] = sfmt("%4d %-13s %s%s", ins.Pc, ins.Name, ops, note and ("  ; "..note) or "")
		end
	end
	analyzeGraph(g)
	for _, l in ipairs(g.Loops) do
		local n = l.Latch.Last and l.Latch.Last.Name
		l.Kind = n == "FORNLOOP" and "numeric for" or n == "FORGLOOP" and "generic for" or n == "JUMPBACK" and "while/repeat" or nil
	end
	return g
end

Core.ReportBytecodeCFA = function(chunk)
	local out = {"-- Script Analyzer :: Control Flow Analysis (bytecode)",
		"-- '*' marks a back edge (loop). Fastcall fallback paths are folded into their block.", ""}
	local totalBlocks, totalLoops = 0, 0
	for id = 0, chunk.ProtoCount - 1 do
		local g = Core.BuildProtoGraph(chunk, chunk.Protos[id])
		totalBlocks += #g.Blocks
		totalLoops += #g.Loops
		renderGraph(g, out)
	end
	insert(out, 3, sfmt("-- %d functions, %d basic blocks, %d loops", chunk.ProtoCount, totalBlocks, totalLoops))
	return concat(out, "\n")
end

---------------------------------------------------------------------------------------------------
-- Bytecode code generation (lifted register-level pseudo-code)
---------------------------------------------------------------------------------------------------
local ARITH = {ADD = "+", SUB = "-", MUL = "*", DIV = "/", MOD = "%", POW = "^", IDIV = "//"}

Core.LiftProto = function(chunk, p, out)
	local g = Core.BuildProtoGraph(chunk, p)
	local blockAt = {}
	for _, b in ipairs(g.Blocks) do blockAt[b.Insns[1].Pc] = b end
	local function L(pc) local b = blockAt[pc] return b and ("B"..b.Id) or ("pc"..tostring(pc)) end
	local function R(r, pc)
		local n = regName(p, r, pc)
		return n and isIdent(n) and n or ("r"..r)
	end
	local function U(u) local n = p.Upvalues[u + 1] return n and isIdent(n) and ("up_"..n) or ("up"..u) end
	local function K(k) return constText(chunk, p, k) end
	local function index(obj, key)
		if isIdent(key) then return obj.."."..key end
		return obj.."["..quote(key or "?").."]"
	end
	local function range(from, count, pc)
		local t = {}
		for r = from, from + count - 1 do t[#t+1] = R(r, pc) end
		return t
	end

	local params = {}
	for r = 0, p.NumParams - 1 do params[#params+1] = R(r, 0) end
	if p.IsVararg then params[#params+1] = "..." end
	out[#out+1] = sfmt("function proto_%d(%s) -- %s, line %d", p.Id, concat(params, ", "), p.DebugName or (p.Id == chunk.MainId and "main" or "anonymous"), p.LineDefined)

	local skip = {}
	local depth = "\t"
	for _, b in ipairs(g.Blocks) do
		if #g.Blocks > 1 then out[#out+1] = sfmt("::B%d::%s", b.Id, b.Reachable and "" or " -- unreachable") end
		for _, i in ipairs(b.Insns) do
			if not skip[i.Pc] then
				local n, A, B, C, D, pc = i.Name, i.A, i.B, i.C, i.D, i.Pc
				-- a local's debug range starts after the instruction that defines it
				local function W(r) return R(r, pc + i.Len) end
				local s
				if n == "NOP" or n == "BREAK" or n == "COVERAGE" or n == "NATIVECALL" or n == "PREPVARARGS" or FASTCALL_OPS[i.Op] then
					s = nil
				elseif n == "LOADNIL" then s = R(A, pc).." = nil"
				elseif n == "LOADB" then
					s = W(A).." = "..tostring(B ~= 0)
					if C ~= 0 then s = s.."; goto "..L(i.Target) end
				elseif n == "LOADN" then s = W(A).." = "..D
				elseif n == "LOADK" then s = W(A).." = "..K(D)
				elseif n == "LOADKX" then s = W(A).." = "..K(i.Aux)
				elseif n == "MOVE" then s = W(A).." = "..R(B, pc)
				elseif n == "GETGLOBAL" then s = W(A).." = "..(kString(p, i.Aux) or "?")
				elseif n == "SETGLOBAL" then s = (kString(p, i.Aux) or "?").." = "..R(A, pc)
				elseif n == "GETUPVAL" then s = W(A).." = "..U(B)
				elseif n == "SETUPVAL" then s = U(B).." = "..R(A, pc)
				elseif n == "CLOSEUPVALS" then s = "-- close upvalues >= "..R(A, pc)
				elseif n == "GETIMPORT" then s = W(A).." = "..importPath(p, i.Aux)
				elseif n == "GETTABLE" then s = W(A).." = "..R(B, pc).."["..R(C, pc).."]"
				elseif n == "SETTABLE" then s = R(B, pc).."["..R(C, pc).."] = "..R(A, pc)
				elseif n == "GETTABLEKS" or n == "GETUDATAKS" then s = W(A).." = "..index(R(B, pc), kString(p, n == "GETTABLEKS" and i.Aux or band(i.Aux, 0xffff)))
				elseif n == "SETTABLEKS" or n == "SETUDATAKS" then s = index(R(B, pc), kString(p, n == "SETTABLEKS" and i.Aux or band(i.Aux, 0xffff))).." = "..R(A, pc)
				elseif n == "GETTABLEN" then s = W(A).." = "..R(B, pc).."["..(C + 1).."]"
				elseif n == "SETTABLEN" then s = R(B, pc).."["..(C + 1).."] = "..R(A, pc)
				elseif n == "NEWCLOSURE" then s = R(A, pc).." = proto_"..tostring(p.Children[D + 1])
				elseif n == "DUPCLOSURE" then s = W(A).." = "..K(D)
				elseif n == "CAPTURE" then s = "-- capture "..(CAPTURE_TYPES[A] or "?").." "..(A == 2 and U(B) or R(B, pc))
				elseif n == "NAMECALL" or n == "NAMECALLUDATA" then
					-- Fold NAMECALL + CALL into obj:method(args)
					local method = kString(p, n == "NAMECALL" and i.Aux or band(i.Aux, 0xffff)) or "?"
					local call = p.Insns[pc + i.Len]
					if call and (call.Name == "CALL" or call.Name == "CALLFB") and call.A == A then
						skip[call.Pc] = true
						local args = call.B == 0 and {"..."} or range(A + 2, call.B - 2, pc)
						if call.B == 0 then insert(args, 1, R(A + 2, pc)) end
						local rhs = R(B, pc)..":"..method.."("..concat(args, ", ")..")"
						if call.C == 1 then s = rhs
						elseif call.C == 0 then s = R(A, pc)..", ... = "..rhs
						else s = concat(range(A, call.C - 1, call.Pc + 1), ", ").." = "..rhs end
					else
						s = W(A).." = "..R(B, pc).."."..method.."; "..R(A + 1, pc).." = "..R(B, pc)
					end
				elseif n == "CALL" or n == "CALLFB" then
					local args = B == 0 and {R(A + 1, pc), "..."} or range(A + 1, B - 1, pc)
					local rhs = R(A, pc).."("..concat(args, ", ")..")"
					if C == 1 then s = rhs
					elseif C == 0 then s = R(A, pc)..", ... = "..rhs
					else s = concat(range(A, C - 1, pc + 1), ", ").." = "..rhs end
				elseif n == "RETURN" then
					if B == 0 then s = "return "..R(A, pc)..", ..."
					elseif B == 1 then s = "return"
					else s = "return "..concat(range(A, B - 1, pc), ", ") end
				elseif n == "JUMP" or n == "JUMPBACK" or n == "JUMPX" then s = "goto "..L(i.Target)
				elseif n == "JUMPIF" then s = "if "..R(A, pc).." then goto "..L(i.Target).." end"
				elseif n == "JUMPIFNOT" then s = "if not "..R(A, pc).." then goto "..L(i.Target).." end"
				elseif n:match("^JUMPIF") then
					local cmp = ({JUMPIFEQ = "==", JUMPIFLE = "<=", JUMPIFLT = "<", JUMPIFNOTEQ = "~=", JUMPIFNOTLE = ">", JUMPIFNOTLT = ">="})[n]
					local lhs, rhs = R(A, pc), R(i.Aux, pc)
					if n == "JUMPIFNOTLE" or n == "JUMPIFNOTLT" then cmp = n == "JUMPIFNOTLE" and "<=" or "<" s = "if not ("..lhs.." "..cmp.." "..rhs..") then goto "..L(i.Target).." end"
					else s = "if "..lhs.." "..cmp.." "..rhs.." then goto "..L(i.Target).." end" end
				elseif n == "JUMPXEQKNIL" or n == "JUMPXEQKB" or n == "JUMPXEQKN" or n == "JUMPXEQKS" then
					local value = n == "JUMPXEQKNIL" and "nil" or n == "JUMPXEQKB" and tostring(band(i.Aux, 1) ~= 0) or K(band(i.Aux, 0xffffff))
					s = "if "..R(A, pc)..(rshift(i.Aux, 31) ~= 0 and " ~= " or " == ")..value.." then goto "..L(i.Target).." end"
				elseif ARITH[n] then s = W(A).." = "..R(B, pc).." "..ARITH[n].." "..R(C, pc)
				elseif n:match("K$") and ARITH[n:sub(1, -2)] then s = W(A).." = "..R(B, pc).." "..ARITH[n:sub(1, -2)].." "..K(C)
				elseif n == "SUBRK" or n == "DIVRK" then s = W(A).." = "..K(B)..(n == "SUBRK" and " - " or " / ")..R(C, pc)
				elseif n == "AND" or n == "OR" then s = W(A).." = "..R(B, pc).." "..n:lower().." "..R(C, pc)
				elseif n == "ANDK" or n == "ORK" then s = W(A).." = "..R(B, pc).." "..n:sub(1, -2):lower().." "..K(C)
				elseif n == "CONCAT" then s = W(A).." = "..concat(range(B, C - B + 1, pc), " .. ")
				elseif n == "NOT" then s = R(A, pc).." = not "..R(B, pc)
				elseif n == "MINUS" then s = R(A, pc).." = -"..R(B, pc)
				elseif n == "LENGTH" then s = R(A, pc).." = #"..R(B, pc)
				elseif n == "NEWTABLE" then s = R(A, pc).." = {}"..((i.Aux or 0) > 0 and (" -- array size "..i.Aux) or "")
				elseif n == "DUPTABLE" then s = W(A).." = "..K(D)
				elseif n == "SETLIST" then
					local vals = C == 0 and {R(B, pc), "..."} or range(B, C - 1, pc)
					s = R(A, pc).."["..i.Aux.."..] = "..concat(vals, ", ")
				elseif n == "GETVARARGS" then
					s = (B == 0 and (R(A, pc)..", ...") or concat(range(A, B - 1, pc), ", ")).." = ..."
				elseif n == "FORNPREP" then
					s = sfmt("for %s = %s, %s, %s do -- exits to %s", R(A + 2, pc + 1), R(A + 2, pc), R(A, pc), R(A + 1, pc), L(i.Target))
				elseif n == "FORNLOOP" then
					s = sfmt("%s += %s; if %s <= %s then goto %s end -- numeric for step", R(A + 2, pc), R(A + 1, pc), R(A + 2, pc), R(A, pc), L(i.Target))
				elseif n == "FORGPREP" or n == "FORGPREP_NEXT" or n == "FORGPREP_INEXT" then
					s = sfmt("-- generic for: gen=%s state=%s ctl=%s; goto %s", R(A, pc), R(A + 1, pc), R(A + 2, pc), L(i.Target))
				elseif n == "FORGLOOP" then
					local vars = range(A + 3, band(i.Aux, 255), pc)
					s = sfmt("%s = %s(%s, %s); if %s ~= nil then goto %s end", concat(vars, ", "), R(A, pc), R(A + 1, pc), R(A + 2, pc), vars[1] or "?", L(i.Target))
				elseif n == "CMPPROTO" then s = sfmt("if not isproto(%s, %d) then goto %s end", R(A, pc), i.Aux, L(i.Target))
				else
					local ops, note = disasmInsn(chunk, p, i)
					s = "-- "..n.." "..ops..(note and ("  ; "..note) or "")
				end
				if s then out[#out+1] = depth..s end
			end
		end
	end
	out[#out+1] = "end"
	out[#out+1] = ""
end

Core.ReportBytecodeCodegen = function(chunk)
	local out = {"-- Script Analyzer :: Code Generation (lifted from bytecode)",
		"-- Register level pseudo-Luau: one statement per instruction, labels are basic blocks.",
		"-- 'goto' and '::label::' are not valid Luau, this is a reading aid, not a decompilation.", ""}
	-- Children first so the main function reads last, like the original file
	for id = 0, chunk.ProtoCount - 1 do
		if id ~= chunk.MainId then Core.LiftProto(chunk, chunk.Protos[id], out) end
	end
	Core.LiftProto(chunk, chunk.Protos[chunk.MainId], out)
	return concat(out, "\n")
end

---------------------------------------------------------------------------------------------------
-- Luau lexer
---------------------------------------------------------------------------------------------------
local KEYWORDS = {}
for kw in ("and break do else elseif end false for function if in local nil not or repeat return then true until while"):gmatch("%a+") do
	KEYWORDS[kw] = true
end
local OPERATORS = {"...", "..=", "//=", "==", "~=", "<=", ">=", "->", "::", "+=", "-=", "*=", "/=", "%=", "^=", "..", "//"}

Core.Lex = function(src, firstLine)
	local tokens = {}
	local pos, line, len = 1, firstLine or 1, #src
	local function push(t, v, s, e, l)
		tokens[#tokens+1] = {T = t, V = v, S = s, E = e, Line = l}
	end
	local function longBracket(at)
		local eq = src:match("^%[(=*)%[", at)
		if not eq then return nil end
		local close = "]"..eq.."]"
		local _, stop = src:find(close, at + #eq + 2, true)
		if not stop then error(sfmt("line %d: unfinished long string/comment", line), 0) end
		return stop
	end
	while pos <= len do
		local c = src:sub(pos, pos)
		if c == "\n" then
			line += 1
			pos += 1
		elseif c:match("%s") then
			pos += 1
		elseif src:sub(pos, pos + 1) == "--" then
			local stop = longBracket(pos + 2)
			if stop then
				local _, n = src:sub(pos, stop):gsub("\n", "")
				line += n
				pos = stop + 1
			else
				local e = src:find("\n", pos, true)
				pos = e or len + 1
			end
		elseif c:match("[%a_]") then
			local s, e = src:find("^[%w_]+", pos)
			local word = src:sub(s, e)
			push(KEYWORDS[word] and "kw" or "name", word, s, e, line)
			pos = e + 1
		elseif c:match("%d") or (c == "." and src:sub(pos + 1, pos + 1):match("%d")) then
			local s, e = src:find("^0[xXbB][%x_]+", pos)
			if not s then
				s, e = src:find("^[%d_]*%.?[%d_]*", pos)
				local _, e2 = src:find("^[eE][%+%-]?[%d_]+", e + 1)
				if e2 then e = e2 end
			end
			push("number", src:sub(s, e), s, e, line)
			pos = e + 1
		elseif c == "\"" or c == "'" then
			local s, l0 = pos, line
			pos += 1
			while true do
				local ch = src:sub(pos, pos)
				if ch == "" or ch == "\n" then error(sfmt("line %d: unfinished string", l0), 0) end
				if ch == "\\" then
					local nxt = src:sub(pos + 1, pos + 1)
					if nxt == "\n" then line += 1 end
					if nxt == "z" then
						local _, e = src:find("^%s*", pos + 2)
						local _, n = src:sub(pos + 2, e):gsub("\n", "")
						line += n
						pos = e + 1
					else
						pos += 2
					end
				elseif ch == c then
					break
				else
					pos += 1
				end
			end
			push("string", src:sub(s, pos), s, pos, l0)
			pos += 1
		elseif c == "`" then
			-- Interpolated string, kept raw; parser splits the {expr} parts
			local s, l0, depth = pos, line, 0
			pos += 1
			while true do
				local ch = src:sub(pos, pos)
				if ch == "" then error(sfmt("line %d: unfinished interpolated string", l0), 0) end
				if ch == "\n" then line += 1 end
				if ch == "\\" then pos += 2
				elseif ch == "{" then depth += 1 pos += 1
				elseif ch == "}" then depth -= 1 pos += 1
				elseif ch == "`" and depth == 0 then break
				elseif depth > 0 and (ch == "\"" or ch == "'") then
					local e = pos + 1
					while src:sub(e, e) ~= ch and e <= len do e += src:sub(e, e) == "\\" and 2 or 1 end
					pos = e + 1
				else pos += 1 end
			end
			push("interp", src:sub(s, pos), s, pos, l0)
			pos += 1
		elseif c == "[" and src:match("^%[=*%[", pos) then
			local stop = longBracket(pos)
			local raw = src:sub(pos, stop)
			push("string", raw, pos, stop, line)
			local _, n = raw:gsub("\n", "")
			line += n
			pos = stop + 1
		else
			local op
			for _, o in ipairs(OPERATORS) do
				if src:sub(pos, pos + #o - 1) == o then op = o break end
			end
			op = op or c
			push("op", op, pos, pos + #op - 1, line)
			pos += #op
		end
	end
	push("eof", "<eof>", len + 1, len, line)
	return tokens
end

-- Decodes a quoted or long string literal into its value (used by the extraction stage)
local function decodeString(raw)
	if raw:sub(1, 1) == "[" then
		local eq = raw:match("^%[(=*)%[")
		local body = raw:sub(#eq + 3, -#eq - 3)
		return (body:gsub("^\r?\n", ""))
	end
	local body = raw:sub(2, -2)
	local escapes = {n = "\n", t = "\t", r = "\r", a = "\a", b = "\b", f = "\f", v = "\v", ["\\"] = "\\", ["\""] = "\"", ["'"] = "'", ["\n"] = "\n"}
	body = body:gsub("\\(z%s*)", "")
	body = body:gsub("\\(%d%d?%d?)", function(d) return string.char(math.min(tonumber(d), 255)) end)
	body = body:gsub("\\x(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
	body = body:gsub("\\u{(%x+)}", function(h) local ok, ch = pcall(utf8.char, tonumber(h, 16)) return ok and ch or "" end)
	body = body:gsub("\\(.)", function(ch) return escapes[ch] or ch end)
	return body
end
Core.DecodeString = decodeString

---------------------------------------------------------------------------------------------------
-- Luau parser -> AST
---------------------------------------------------------------------------------------------------
local BINARY_PRIORITY = {
	["+"] = {6, 6}, ["-"] = {6, 6}, ["*"] = {7, 7}, ["/"] = {7, 7}, ["//"] = {7, 7}, ["%"] = {7, 7},
	["^"] = {10, 9}, [".."] = {5, 4},
	["=="] = {3, 3}, ["~="] = {3, 3}, ["<"] = {3, 3}, ["<="] = {3, 3}, [">"] = {3, 3}, [">="] = {3, 3},
	["and"] = {2, 2}, ["or"] = {1, 1},
}
local UNARY_PRIORITY = 8
local COMPOUND = {["+="] = "+", ["-="] = "-", ["*="] = "*", ["/="] = "/", ["//="] = "//", ["%="] = "%", ["^="] = "^", ["..="] = ".."}
Core.BinaryPriority = BINARY_PRIORITY

Core.Parse = function(src, firstLine)
	local tokens = Core.Lex(src, firstLine)
	local p = 1
	local tok = tokens[1]
	local lastEnd = 0
	local functions = {}

	local function advance()
		lastEnd = tok.E
		p += 1
		tok = tokens[p]
		return tokens[p - 1]
	end
	local function peek(n) return tokens[p + (n or 1)] or tokens[#tokens] end
	local function isOp(v) return tok.T == "op" and tok.V == v end
	local function isKw(v) return tok.T == "kw" and tok.V == v end
	local function fail(msg) error(sfmt("line %d: %s near '%s'", tok.Line, msg, tok.V), 0) end
	local function expectOp(v) if not isOp(v) then fail("'"..v.."' expected") end return advance() end
	local function expectKw(v, openLine)
		if not isKw(v) then fail("'"..v.."' expected"..(openLine and (" (to close line "..openLine..")") or "")) end
		return advance()
	end
	local function expectName()
		if tok.T ~= "name" then fail("name expected") end
		return advance().V
	end

	-- Types are kept as raw source text, they only need to be skipped correctly
	local skipType
	local function skipBalanced(open, close)
		local depth = 0
		repeat
			if tok.T == "eof" then fail("unbalanced '"..open.."'") end
			if isOp(open) then depth += 1 elseif isOp(close) then depth -= 1 end
			advance()
		until depth == 0
	end
	local function skipSimpleType()
		if isOp("|") or isOp("&") then advance() end
		if isOp("(") then
			skipBalanced("(", ")")
			if isOp("->") then advance() skipType() end
		elseif isOp("{") then
			skipBalanced("{", "}")
		elseif isOp("<") then
			skipBalanced("<", ">")
			if isOp("(") then skipBalanced("(", ")") end
			if isOp("->") then advance() skipType() end
		elseif isOp("...") then
			advance()
			skipSimpleType()
		elseif tok.T == "name" and tok.V == "typeof" then
			advance()
			if isOp("(") then skipBalanced("(", ")") end
		elseif tok.T == "name" or tok.T == "kw" or tok.T == "string" then
			advance()
			while isOp(".") do advance() advance() end
			if isOp("<") then skipBalanced("<", ">") end
			if isOp("...") then advance() end
		else
			fail("type expected")
		end
	end
	skipType = function()
		local s = tok.S
		skipSimpleType()
		while true do
			if isOp("|") or isOp("&") then advance() skipSimpleType()
			elseif isOp("?") then advance()
			else break end
		end
		return src:sub(s, lastEnd)
	end
	local function typeAnnotation()
		if isOp(":") then advance() return skipType() end
		return nil
	end
	local function skipGenerics()
		if isOp("<") then
			local s = tok.S
			skipBalanced("<", ">")
			return src:sub(s, lastEnd)
		end
		return nil
	end
	local function skipAttributes()
		local attrs = {}
		while isOp("@") do
			advance()
			if isOp("[") then skipBalanced("[", "]") else attrs[#attrs+1] = "@"..expectName() end
		end
		return attrs
	end

	local block, expr, funcBody, primaryExpr

	local function exprList()
		local list = {expr()}
		while isOp(",") do advance() list[#list+1] = expr() end
		return list
	end

	local function tableConstructor()
		local line = tok.Line
		expectOp("{")
		local fields = {}
		while not isOp("}") do
			if isOp("[") then
				advance()
				local key = expr()
				expectOp("]")
				expectOp("=")
				fields[#fields+1] = {Kind = "Index", Key = key, Value = expr()}
			elseif tok.T == "name" and peek().T == "op" and peek().V == "=" then
				local name = advance().V
				advance()
				fields[#fields+1] = {Kind = "Name", Name = name, Value = expr()}
			else
				fields[#fields+1] = {Kind = "List", Value = expr()}
			end
			if isOp(",") or isOp(";") then advance() elseif not isOp("}") then fail("'}' expected (to close '{' at line "..line..")") end
		end
		advance()
		return {Kind = "Table", Fields = fields, Line = line}
	end

	local function interpString(t)
		-- Split `text {expr} text` into string parts and parsed expressions
		local raw = t.V
		local parts, exprs = {}, {}
		local body = raw:sub(2, -2)
		local i, buf = 1, {}
		while i <= #body do
			local ch = body:sub(i, i)
			if ch == "\\" then
				buf[#buf+1] = body:sub(i, i + 1)
				i += 2
			elseif ch == "{" then
				local depth, j = 1, i + 1
				while j <= #body and depth > 0 do
					local cj = body:sub(j, j)
					if cj == "{" then depth += 1 elseif cj == "}" then depth -= 1
					elseif cj == "\"" or cj == "'" then
						j += 1
						while j <= #body and body:sub(j, j) ~= cj do j += body:sub(j, j) == "\\" and 2 or 1 end
					end
					j += 1
				end
				parts[#parts+1] = concat(buf)
				buf = {}
				local inner = Core.Parse("return "..body:sub(i + 1, j - 2), t.Line)
				exprs[#exprs+1] = inner.Body[1].Values[1]
				i = j
			else
				buf[#buf+1] = ch
				i += 1
			end
		end
		parts[#parts+1] = concat(buf)
		return {Kind = "InterpString", Raw = raw, Parts = parts, Exprs = exprs, Line = t.Line}
	end

	local function callArgs()
		if tok.T == "string" then
			local t = advance()
			return {{Kind = "String", Raw = t.V, Line = t.Line}}
		elseif isOp("{") then
			return {tableConstructor()}
		end
		expectOp("(")
		local args = {}
		if not isOp(")") then args = exprList() end
		expectOp(")")
		return args
	end

	primaryExpr = function()
		local e
		local line = tok.Line
		if tok.T == "name" then
			e = {Kind = "Name", Name = advance().V, Line = line}
		elseif isOp("(") then
			advance()
			e = {Kind = "Paren", Expr = expr(), Line = line}
			expectOp(")")
		else
			fail("unexpected symbol")
		end
		while true do
			line = tok.Line
			if isOp(".") then
				advance()
				e = {Kind = "Index", Obj = e, Key = expectName(), Line = line}
			elseif isOp("[") then
				advance()
				local key = expr()
				expectOp("]")
				e = {Kind = "IndexExpr", Obj = e, Key = key, Line = line}
			elseif isOp(":") then
				advance()
				local method = expectName()
				e = {Kind = "MethodCall", Obj = e, Method = method, Args = callArgs(), Line = line}
			elseif isOp("(") or isOp("{") or tok.T == "string" then
				e = {Kind = "Call", Func = e, Args = callArgs(), Line = line}
			else
				return e
			end
		end
	end

	local function simpleExpr()
		local t = tok
		local e
		if t.T == "number" then advance() e = {Kind = "Number", Raw = t.V, Line = t.Line}
		elseif t.T == "string" then advance() e = {Kind = "String", Raw = t.V, Line = t.Line}
		elseif t.T == "interp" then advance() e = interpString(t)
		elseif isKw("nil") then advance() e = {Kind = "Nil", Line = t.Line}
		elseif isKw("true") or isKw("false") then advance() e = {Kind = "Boolean", Value = t.V == "true", Line = t.Line}
		elseif isOp("...") then advance() e = {Kind = "Vararg", Line = t.Line}
		elseif isOp("{") then e = tableConstructor()
		elseif isKw("function") then
			advance()
			e = funcBody(t.Line, nil)
		elseif isOp("@") then
			local attrs = skipAttributes()
			local line = tok.Line
			expectKw("function")
			e = funcBody(line, nil)
			e.Attributes = attrs
		elseif isKw("if") then
			advance()
			local clauses = {{Cond = expr()}}
			expectKw("then")
			clauses[1].Value = expr()
			while isKw("elseif") do
				advance()
				local c = {Cond = expr()}
				expectKw("then")
				c.Value = expr()
				clauses[#clauses+1] = c
			end
			expectKw("else")
			e = {Kind = "IfExpr", Clauses = clauses, Else = expr(), Line = t.Line}
		else
			e = primaryExpr()
		end
		while isOp("::") do
			advance()
			e = {Kind = "TypeAssert", Expr = e, Type = skipType(), Line = t.Line}
		end
		return e
	end

	local function subExpr(limit)
		local e
		local line = tok.Line
		if isKw("not") or isOp("-") or isOp("#") then
			local op = advance().V
			e = {Kind = "Unary", Op = op, Expr = subExpr(UNARY_PRIORITY), Line = line}
		else
			e = simpleExpr()
		end
		while true do
			local op = (tok.T == "op" or isKw("and") or isKw("or")) and tok.V
			local prio = op and BINARY_PRIORITY[op]
			if not prio or prio[1] <= limit then break end
			line = tok.Line
			advance()
			e = {Kind = "Binary", Op = op, Left = e, Right = subExpr(prio[2]), Line = line}
		end
		return e
	end
	expr = function() return subExpr(0) end

	funcBody = function(line, name, isMethod)
		local fn = {Kind = "Function", Name = name, Params = {}, Line = line, IsMethod = isMethod}
		fn.Generics = skipGenerics()
		expectOp("(")
		while not isOp(")") do
			if isOp("...") then
				advance()
				fn.Vararg = true
				fn.VarargType = typeAnnotation()
			else
				fn.Params[#fn.Params+1] = {Name = expectName(), Type = typeAnnotation()}
			end
			if isOp(",") then advance() elseif not isOp(")") then fail("')' expected") end
		end
		advance()
		fn.ReturnType = typeAnnotation()
		fn.Body = block()
		expectKw("end", line)
		fn.EndLine = tokens[p - 1].Line
		functions[#functions+1] = fn
		return fn
	end

	local function isBlockEnd()
		return tok.T == "eof" or isKw("end") or isKw("else") or isKw("elseif") or isKw("until")
	end

	local function statement()
		local line = tok.Line
		local t = tok
		if isKw("if") then
			advance()
			local clauses = {}
			local c = {Cond = expr()}
			expectKw("then")
			c.Body = block()
			clauses[1] = c
			local elseBody
			while true do
				if isKw("elseif") then
					advance()
					local c2 = {Cond = expr()}
					expectKw("then")
					c2.Body = block()
					clauses[#clauses+1] = c2
				elseif isKw("else") then
					advance()
					elseBody = block()
					expectKw("end", line)
					break
				else
					expectKw("end", line)
					break
				end
			end
			return {Kind = "If", Clauses = clauses, Else = elseBody, Line = line}
		elseif isKw("while") then
			advance()
			local cond = expr()
			expectKw("do")
			local body = block()
			expectKw("end", line)
			return {Kind = "While", Cond = cond, Body = body, Line = line}
		elseif isKw("do") then
			advance()
			local body = block()
			expectKw("end", line)
			return {Kind = "Do", Body = body, Line = line}
		elseif isKw("for") then
			advance()
			local first = {Name = expectName(), Type = typeAnnotation()}
			if isOp("=") then
				advance()
				local start = expr()
				expectOp(",")
				local limit = expr()
				local step
				if isOp(",") then advance() step = expr() end
				expectKw("do")
				local body = block()
				expectKw("end", line)
				return {Kind = "NumericFor", Var = first, Start = start, Limit = limit, Step = step, Body = body, Line = line}
			end
			local vars = {first}
			while isOp(",") do
				advance()
				vars[#vars+1] = {Name = expectName(), Type = typeAnnotation()}
			end
			expectKw("in")
			local exprs = exprList()
			expectKw("do")
			local body = block()
			expectKw("end", line)
			return {Kind = "GenericFor", Vars = vars, Exprs = exprs, Body = body, Line = line}
		elseif isKw("repeat") then
			advance()
			local body = block()
			expectKw("until", line)
			return {Kind = "Repeat", Body = body, Cond = expr(), Line = line}
		elseif isKw("function") then
			advance()
			local target = {Kind = "Name", Name = expectName(), Line = line}
			local isMethod = false
			local nameParts = {target.Name}
			while isOp(".") do
				advance()
				local key = expectName()
				target = {Kind = "Index", Obj = target, Key = key, Line = line}
				nameParts[#nameParts+1] = "."..key
			end
			if isOp(":") then
				advance()
				local key = expectName()
				target = {Kind = "Index", Obj = target, Key = key, Line = line}
				nameParts[#nameParts+1] = ":"..key
				isMethod = true
			end
			local fn = funcBody(line, concat(nameParts), isMethod)
			return {Kind = "FunctionDecl", Target = target, Func = fn, IsMethod = isMethod, Line = line}
		elseif isOp("@") then
			local attrs = skipAttributes()
			local s = statement()
			local fn = s.Func
			if fn then fn.Attributes = attrs end
			return s
		elseif isKw("local") then
			advance()
			if isOp("@") or isKw("function") then
				local attrs = skipAttributes()
				expectKw("function")
				local name = expectName()
				local fn = funcBody(line, name)
				fn.Attributes = attrs
				return {Kind = "LocalFunction", Name = name, Func = fn, Line = line}
			end
			local names = {}
			repeat
				if #names > 0 then advance() end
				local n = {Name = expectName()}
				if isOp("<") then -- <const>/<close> attribs
					advance()
					n.Attrib = expectName()
					expectOp(">")
				end
				n.Type = typeAnnotation()
				names[#names+1] = n
			until not isOp(",")
			local values = {}
			if isOp("=") then advance() values = exprList() end
			return {Kind = "Local", Names = names, Values = values, Line = line}
		elseif isKw("return") then
			advance()
			local values = {}
			if not isBlockEnd() and not isOp(";") then values = exprList() end
			return {Kind = "Return", Values = values, Line = line}
		elseif isKw("break") then
			advance()
			return {Kind = "Break", Line = line}
		elseif t.T == "name" and t.V == "continue" and (peek().T == "kw" or peek().T == "eof" or (peek().T == "name") or (peek().T == "op" and peek().V == ";")) then
			advance()
			return {Kind = "Continue", Line = line}
		elseif t.T == "name" and ((t.V == "type" and peek().T == "name") or (t.V == "export" and peek().T == "name" and peek().V == "type" and peek(2).T == "name")) then
			local exported = t.V == "export"
			if exported then advance() end
			advance()
			local name = expectName()
			local generics = skipGenerics()
			expectOp("=")
			return {Kind = "TypeAlias", Exported = exported, Name = name, Generics = generics, Type = skipType(), Line = line}
		end

		-- Expression statement: call, assignment or compound assignment
		local e = primaryExpr()
		if isOp("=") or isOp(",") then
			local targets = {e}
			while isOp(",") do
				advance()
				targets[#targets+1] = primaryExpr()
			end
			expectOp("=")
			for _, target in ipairs(targets) do
				if target.Kind ~= "Name" and target.Kind ~= "Index" and target.Kind ~= "IndexExpr" then fail("syntax error, cannot assign to this expression") end
			end
			return {Kind = "Assign", Targets = targets, Values = exprList(), Line = line}
		elseif tok.T == "op" and COMPOUND[tok.V] then
			local op = COMPOUND[advance().V]
			return {Kind = "CompoundAssign", Op = op, Target = e, Value = expr(), Line = line}
		end
		if e.Kind ~= "Call" and e.Kind ~= "MethodCall" then fail("syntax error, expression is not a statement") end
		return {Kind = "CallStatement", Call = e, Line = line}
	end

	block = function()
		local stmts = {}
		while not isBlockEnd() do
			if isOp(";") then
				advance()
			else
				local s = statement()
				stmts[#stmts+1] = s
				if isOp(";") then advance() end
				if s.Kind == "Return" or s.Kind == "Break" or s.Kind == "Continue" then
					if not isBlockEnd() then
						-- Luau requires these to end the block; keep going but remember it
						s.NotLast = true
					end
				end
			end
		end
		return stmts
	end

	local body = block()
	if tok.T ~= "eof" then fail("'<eof>' expected") end
	local main = {Kind = "Function", Name = "main chunk", Params = {}, Vararg = true, Body = body, Line = 1, EndLine = tok.Line, IsMain = true}
	table.insert(functions, 1, main)
	return {Kind = "Chunk", Body = body, Main = main, Functions = functions, TokenCount = #tokens - 1, LineCount = tok.Line}
end

---------------------------------------------------------------------------------------------------
-- Scope resolution: tags every Name with Local/Upvalue/Global
---------------------------------------------------------------------------------------------------
Core.Resolve = function(ast)
	local globals, localCount = {}, 0
	local scope = nil
	local fnDepth = 0
	local visitExpr, visitBlock

	local function push() scope = {Vars = {}, Parent = scope, Fn = fnDepth} end
	local function pop() scope = scope.Parent end
	local function declare(name, line)
		scope.Vars[name] = {Fn = fnDepth, Line = line}
		localCount += 1
	end
	local function lookup(name)
		local s = scope
		while s do
			local v = s.Vars[name]
			if v then return v end
			s = s.Parent
		end
		return nil
	end

	local function visitFunction(fn)
		fnDepth += 1
		push()
		if fn.IsMethod then declare("self", fn.Line) end
		for _, prm in ipairs(fn.Params) do declare(prm.Name, fn.Line) end
		visitBlock(fn.Body, true)
		pop()
		fnDepth -= 1
	end

	visitExpr = function(e)
		if not e then return end
		local k = e.Kind
		if k == "Name" then
			local v = lookup(e.Name)
			if v then
				e.Scope = v.Fn == fnDepth and "local" or "upvalue"
			else
				e.Scope = "global"
				globals[e.Name] = (globals[e.Name] or 0) + 1
			end
		elseif k == "Paren" or k == "TypeAssert" then visitExpr(e.Expr)
		elseif k == "Unary" then visitExpr(e.Expr)
		elseif k == "Binary" then visitExpr(e.Left) visitExpr(e.Right)
		elseif k == "Index" then visitExpr(e.Obj)
		elseif k == "IndexExpr" then visitExpr(e.Obj) visitExpr(e.Key)
		elseif k == "Call" then visitExpr(e.Func) for _, a in ipairs(e.Args) do visitExpr(a) end
		elseif k == "MethodCall" then visitExpr(e.Obj) for _, a in ipairs(e.Args) do visitExpr(a) end
		elseif k == "Function" then visitFunction(e)
		elseif k == "Table" then
			for _, f in ipairs(e.Fields) do visitExpr(f.Key) visitExpr(f.Value) end
		elseif k == "IfExpr" then
			for _, c in ipairs(e.Clauses) do visitExpr(c.Cond) visitExpr(c.Value) end
			visitExpr(e.Else)
		elseif k == "InterpString" then
			for _, x in ipairs(e.Exprs) do visitExpr(x) end
		end
	end

	local function visitStmt(s)
		local k = s.Kind
		if k == "Local" then
			for _, v in ipairs(s.Values) do visitExpr(v) end
			for _, n in ipairs(s.Names) do declare(n.Name, s.Line) end
		elseif k == "LocalFunction" then
			declare(s.Name, s.Line)
			visitFunction(s.Func)
		elseif k == "FunctionDecl" then
			visitExpr(s.Target)
			visitFunction(s.Func)
		elseif k == "Assign" then
			for _, v in ipairs(s.Values) do visitExpr(v) end
			for _, t in ipairs(s.Targets) do visitExpr(t) end
		elseif k == "CompoundAssign" then visitExpr(s.Target) visitExpr(s.Value)
		elseif k == "CallStatement" then visitExpr(s.Call)
		elseif k == "Do" then visitBlock(s.Body)
		elseif k == "While" then visitExpr(s.Cond) visitBlock(s.Body)
		elseif k == "Repeat" then
			-- until can see the body's locals
			push()
			visitBlock(s.Body, true)
			visitExpr(s.Cond)
			pop()
		elseif k == "If" then
			for _, c in ipairs(s.Clauses) do visitExpr(c.Cond) visitBlock(c.Body) end
			if s.Else then visitBlock(s.Else) end
		elseif k == "NumericFor" then
			visitExpr(s.Start) visitExpr(s.Limit) visitExpr(s.Step)
			push() declare(s.Var.Name, s.Line) visitBlock(s.Body, true) pop()
		elseif k == "GenericFor" then
			for _, x in ipairs(s.Exprs) do visitExpr(x) end
			push()
			for _, v in ipairs(s.Vars) do declare(v.Name, s.Line) end
			visitBlock(s.Body, true)
			pop()
		elseif k == "Return" then
			for _, v in ipairs(s.Values) do visitExpr(v) end
		end
	end

	visitBlock = function(stmts, noScope)
		if not noScope then push() end
		for _, s in ipairs(stmts) do visitStmt(s) end
		if not noScope then pop() end
	end

	push()
	visitBlock(ast.Body, true)
	pop()
	ast.Globals = globals
	ast.LocalCount = localCount
	return ast
end

---------------------------------------------------------------------------------------------------
-- Code generation from the AST (pretty printer)
---------------------------------------------------------------------------------------------------
local Gen = {}

local function needsParens(child, parentPrio, isRight, parentOp)
	if child.Kind ~= "Binary" then return false end
	local prio = BINARY_PRIORITY[child.Op]
	if prio[1] < parentPrio then return true end
	if prio[1] == parentPrio then
		-- right associative operators (.. and ^) need parens on the left, others on the right
		local rightAssoc = parentOp == ".." or parentOp == "^"
		if rightAssoc then return not isRight end
		return isRight
	end
	return false
end

function Gen.expr(e, ind)
	local k = e.Kind
	if k == "Name" then return e.Name
	elseif k == "Nil" then return "nil"
	elseif k == "Boolean" then return tostring(e.Value)
	elseif k == "Number" or k == "String" then return e.Raw
	elseif k == "InterpString" then return e.Raw
	elseif k == "Vararg" then return "..."
	elseif k == "Paren" then return "("..Gen.expr(e.Expr, ind)..")"
	elseif k == "TypeAssert" then return Gen.expr(e.Expr, ind).." :: "..e.Type
	elseif k == "Index" then return Gen.prefix(e.Obj, ind).."."..e.Key
	elseif k == "IndexExpr" then return Gen.prefix(e.Obj, ind).."["..Gen.expr(e.Key, ind).."]"
	elseif k == "Call" then return Gen.prefix(e.Func, ind)..Gen.args(e.Args, ind)
	elseif k == "MethodCall" then return Gen.prefix(e.Obj, ind)..":"..e.Method..Gen.args(e.Args, ind)
	elseif k == "Unary" then
		local inner = Gen.expr(e.Expr, ind)
		if e.Expr.Kind == "Binary" and BINARY_PRIORITY[e.Expr.Op][1] < UNARY_PRIORITY then inner = "("..inner..")" end
		if e.Op == "not" then return "not "..inner end
		if e.Op == "-" and inner:sub(1, 1) == "-" then return "- "..inner end
		return e.Op..inner
	elseif k == "Binary" then
		local prio = BINARY_PRIORITY[e.Op][1]
		local l, r = Gen.expr(e.Left, ind), Gen.expr(e.Right, ind)
		if needsParens(e.Left, prio, false, e.Op) then l = "("..l..")" end
		if needsParens(e.Right, prio, true, e.Op) then r = "("..r..")" end
		-- -x^2 style unary on the left of ^ binds looser than ^
		if e.Op == "^" and e.Left.Kind == "Unary" then l = "("..l..")" end
		return l.." "..e.Op.." "..r
	elseif k == "Function" then
		return "function"..Gen.funcSig(e)..Gen.body(e.Body, ind).."\n"..srep("\t", ind).."end"
	elseif k == "Table" then
		if #e.Fields == 0 then return "{}" end
		local parts, multiline = {}, #e.Fields > 4
		for _, f in ipairs(e.Fields) do
			local v = Gen.expr(f.Value, ind + 1)
			if v:find("\n") then multiline = true end
			if f.Kind == "Index" then parts[#parts+1] = "["..Gen.expr(f.Key, ind + 1).."] = "..v
			elseif f.Kind == "Name" then parts[#parts+1] = f.Name.." = "..v
			else parts[#parts+1] = v end
		end
		if not multiline then
			local flat = "{"..concat(parts, ", ").."}"
			if #flat <= 80 then return flat end
		end
		local pad = srep("\t", ind + 1)
		return "{\n"..pad..concat(parts, ",\n"..pad)..",\n"..srep("\t", ind).."}"
	elseif k == "IfExpr" then
		local s = ""
		for j, c in ipairs(e.Clauses) do
			s = s..(j == 1 and "if " or " elseif ")..Gen.expr(c.Cond, ind).." then "..Gen.expr(c.Value, ind)
		end
		return s.." else "..Gen.expr(e.Else, ind)
	end
	return "--[[?"..tostring(k).."]]"
end

function Gen.prefix(e, ind)
	local s = Gen.expr(e, ind)
	if e.Kind == "Name" or e.Kind == "Paren" or e.Kind == "Index" or e.Kind == "IndexExpr" or e.Kind == "Call" or e.Kind == "MethodCall" then
		return s
	end
	return "("..s..")"
end

function Gen.args(args, ind)
	local parts = {}
	for j, a in ipairs(args) do parts[j] = Gen.expr(a, ind) end
	return "("..concat(parts, ", ")..")"
end

function Gen.funcSig(fn)
	local params = {}
	for _, prm in ipairs(fn.Params) do
		params[#params+1] = prm.Name..(prm.Type and (": "..prm.Type) or "")
	end
	if fn.Vararg and not fn.IsMain then params[#params+1] = "..."..(fn.VarargType and (": "..fn.VarargType) or "") end
	return (fn.Generics or "").."("..concat(params, ", ")..")"..(fn.ReturnType and (": "..fn.ReturnType) or "")
end

local function exprList(list, ind)
	local parts = {}
	for j, e in ipairs(list) do parts[j] = Gen.expr(e, ind) end
	return concat(parts, ", ")
end

function Gen.body(stmts, ind)
	local out = {}
	for _, s in ipairs(stmts) do out[#out+1] = Gen.stmt(s, ind + 1) end
	if #out == 0 then return "" end
	return "\n"..concat(out, "\n")
end

function Gen.stmt(s, ind)
	local pad = srep("\t", ind)
	local k = s.Kind
	local function attrs(fn) return fn.Attributes and #fn.Attributes > 0 and (concat(fn.Attributes, " ").."\n"..pad) or "" end
	if k == "Local" then
		local names = {}
		for j, n in ipairs(s.Names) do names[j] = n.Name..(n.Attrib and ("<"..n.Attrib..">") or "")..(n.Type and (": "..n.Type) or "") end
		return pad.."local "..concat(names, ", ")..(#s.Values > 0 and (" = "..exprList(s.Values, ind)) or "")
	elseif k == "LocalFunction" then
		return pad..attrs(s.Func).."local function "..s.Name..Gen.funcSig(s.Func)..Gen.body(s.Func.Body, ind).."\n"..pad.."end"
	elseif k == "FunctionDecl" then
		return pad..attrs(s.Func).."function "..s.Func.Name..Gen.funcSig(s.Func)..Gen.body(s.Func.Body, ind).."\n"..pad.."end"
	elseif k == "Assign" then
		return pad..exprList(s.Targets, ind).." = "..exprList(s.Values, ind)
	elseif k == "CompoundAssign" then
		return pad..Gen.expr(s.Target, ind).." "..s.Op.."= "..Gen.expr(s.Value, ind)
	elseif k == "CallStatement" then
		return pad..Gen.expr(s.Call, ind)
	elseif k == "Do" then
		return pad.."do"..Gen.body(s.Body, ind).."\n"..pad.."end"
	elseif k == "While" then
		return pad.."while "..Gen.expr(s.Cond, ind).." do"..Gen.body(s.Body, ind).."\n"..pad.."end"
	elseif k == "Repeat" then
		return pad.."repeat"..Gen.body(s.Body, ind).."\n"..pad.."until "..Gen.expr(s.Cond, ind)
	elseif k == "If" then
		local out = {}
		for j, c in ipairs(s.Clauses) do
			out[#out+1] = (j == 1 and (pad.."if ") or (pad.."elseif "))..Gen.expr(c.Cond, ind).." then"..Gen.body(c.Body, ind)
		end
		if s.Else then out[#out+1] = pad.."else"..Gen.body(s.Else, ind) end
		return concat(out, "\n").."\n"..pad.."end"
	elseif k == "NumericFor" then
		return pad.."for "..s.Var.Name..(s.Var.Type and (": "..s.Var.Type) or "").." = "..Gen.expr(s.Start, ind)..", "..Gen.expr(s.Limit, ind)
			..(s.Step and (", "..Gen.expr(s.Step, ind)) or "").." do"..Gen.body(s.Body, ind).."\n"..pad.."end"
	elseif k == "GenericFor" then
		local vars = {}
		for j, v in ipairs(s.Vars) do vars[j] = v.Name..(v.Type and (": "..v.Type) or "") end
		return pad.."for "..concat(vars, ", ").." in "..exprList(s.Exprs, ind).." do"..Gen.body(s.Body, ind).."\n"..pad.."end"
	elseif k == "Return" then
		return pad.."return"..(#s.Values > 0 and (" "..exprList(s.Values, ind)) or "")
	elseif k == "Break" then return pad.."break"
	elseif k == "Continue" then return pad.."continue"
	elseif k == "TypeAlias" then
		return pad..(s.Exported and "export " or "").."type "..s.Name..(s.Generics or "").." = "..s.Type
	end
	return pad.."--[[?"..tostring(k).."]]"
end

Core.Generate = function(ast)
	local out = {}
	for _, s in ipairs(ast.Body) do out[#out+1] = Gen.stmt(s, 0) end
	return concat(out, "\n")
end
Core.GenExpr = function(e) return Gen.expr(e, 0) end

---------------------------------------------------------------------------------------------------
-- AST dump
---------------------------------------------------------------------------------------------------
local function short(s, n)
	s = s:gsub("%s+", " ")
	if #s > n then return s:sub(1, n - 3).."..." end
	return s
end

Core.DumpAST = function(ast)
	local out = {}
	local function line(depth, text) out[#out+1] = srep("  ", depth)..text end
	local dumpExpr, dumpBlock

	dumpExpr = function(e, depth, label)
		if not e then return end
		local pre = label and (label..": ") or ""
		local k = e.Kind
		if k == "Name" then line(depth, pre..sfmt("Name %s (%s)", e.Name, e.Scope or "?"))
		elseif k == "Number" or k == "String" then line(depth, pre..k.." "..short(e.Raw, 60))
		elseif k == "Boolean" then line(depth, pre.."Boolean "..tostring(e.Value))
		elseif k == "Nil" or k == "Vararg" then line(depth, pre..k)
		elseif k == "InterpString" then
			line(depth, pre.."InterpString "..short(e.Raw, 60))
			for _, x in ipairs(e.Exprs) do dumpExpr(x, depth + 1) end
		elseif k == "Paren" then line(depth, pre.."Paren") dumpExpr(e.Expr, depth + 1)
		elseif k == "TypeAssert" then line(depth, pre.."TypeAssert :: "..short(e.Type, 40)) dumpExpr(e.Expr, depth + 1)
		elseif k == "Unary" then line(depth, pre.."Unary "..e.Op) dumpExpr(e.Expr, depth + 1)
		elseif k == "Binary" then
			line(depth, pre.."Binary "..e.Op)
			dumpExpr(e.Left, depth + 1)
			dumpExpr(e.Right, depth + 1)
		elseif k == "Index" then line(depth, pre.."Index ."..e.Key) dumpExpr(e.Obj, depth + 1)
		elseif k == "IndexExpr" then line(depth, pre.."IndexExpr") dumpExpr(e.Obj, depth + 1, "object") dumpExpr(e.Key, depth + 1, "key")
		elseif k == "Call" then
			line(depth, pre..sfmt("Call (%d args)  [line %d]", #e.Args, e.Line))
			dumpExpr(e.Func, depth + 1, "func")
			for j, a in ipairs(e.Args) do dumpExpr(a, depth + 1, "arg"..j) end
		elseif k == "MethodCall" then
			line(depth, pre..sfmt("MethodCall :%s (%d args)  [line %d]", e.Method, #e.Args, e.Line))
			dumpExpr(e.Obj, depth + 1, "self")
			for j, a in ipairs(e.Args) do dumpExpr(a, depth + 1, "arg"..j) end
		elseif k == "Function" then
			local params = {}
			for j, prm in ipairs(e.Params) do params[j] = prm.Name end
			if e.Vararg then params[#params+1] = "..." end
			line(depth, pre..sfmt("Function (%s)  [lines %d-%d]", concat(params, ", "), e.Line, e.EndLine or e.Line))
			dumpBlock(e.Body, depth + 1)
		elseif k == "Table" then
			line(depth, pre..sfmt("Table (%d fields)", #e.Fields))
			for _, f in ipairs(e.Fields) do
				if f.Kind == "Name" then dumpExpr(f.Value, depth + 1, f.Name)
				elseif f.Kind == "Index" then dumpExpr(f.Key, depth + 1, "[key]") dumpExpr(f.Value, depth + 2, "value")
				else dumpExpr(f.Value, depth + 1, "item") end
			end
		elseif k == "IfExpr" then
			line(depth, pre.."IfExpr")
			for _, c in ipairs(e.Clauses) do dumpExpr(c.Cond, depth + 1, "if") dumpExpr(c.Value, depth + 1, "then") end
			dumpExpr(e.Else, depth + 1, "else")
		else
			line(depth, pre..tostring(k))
		end
	end

	local function dumpStmt(s, depth)
		local k = s.Kind
		local at = sfmt("  [line %d]", s.Line or 0)
		if k == "Local" then
			local names = {}
			for j, n in ipairs(s.Names) do names[j] = n.Name..(n.Type and (": "..short(n.Type, 30)) or "") end
			line(depth, "Local "..concat(names, ", ")..at)
			for _, v in ipairs(s.Values) do dumpExpr(v, depth + 1) end
		elseif k == "LocalFunction" then
			line(depth, "LocalFunction "..s.Name..at)
			dumpExpr(s.Func, depth + 1)
		elseif k == "FunctionDecl" then
			line(depth, "FunctionDecl "..s.Func.Name..at)
			dumpExpr(s.Func, depth + 1)
		elseif k == "Assign" then
			line(depth, "Assign"..at)
			for _, t in ipairs(s.Targets) do dumpExpr(t, depth + 1, "target") end
			for _, v in ipairs(s.Values) do dumpExpr(v, depth + 1, "value") end
		elseif k == "CompoundAssign" then
			line(depth, "CompoundAssign "..s.Op.."="..at)
			dumpExpr(s.Target, depth + 1, "target")
			dumpExpr(s.Value, depth + 1, "value")
		elseif k == "CallStatement" then
			line(depth, "CallStatement"..at)
			dumpExpr(s.Call, depth + 1)
		elseif k == "Do" then line(depth, "Do"..at) dumpBlock(s.Body, depth + 1)
		elseif k == "While" then
			line(depth, "While"..at)
			dumpExpr(s.Cond, depth + 1, "cond")
			dumpBlock(s.Body, depth + 1)
		elseif k == "Repeat" then
			line(depth, "Repeat"..at)
			dumpBlock(s.Body, depth + 1)
			dumpExpr(s.Cond, depth + 1, "until")
		elseif k == "If" then
			line(depth, "If"..at)
			for j, c in ipairs(s.Clauses) do
				dumpExpr(c.Cond, depth + 1, j == 1 and "if" or "elseif")
				dumpBlock(c.Body, depth + 2)
			end
			if s.Else then line(depth + 1, "else") dumpBlock(s.Else, depth + 2) end
		elseif k == "NumericFor" then
			line(depth, "NumericFor "..s.Var.Name..at)
			dumpExpr(s.Start, depth + 1, "start")
			dumpExpr(s.Limit, depth + 1, "limit")
			dumpExpr(s.Step, depth + 1, "step")
			dumpBlock(s.Body, depth + 1)
		elseif k == "GenericFor" then
			local vars = {}
			for j, v in ipairs(s.Vars) do vars[j] = v.Name end
			line(depth, "GenericFor "..concat(vars, ", ")..at)
			for _, x in ipairs(s.Exprs) do dumpExpr(x, depth + 1, "in") end
			dumpBlock(s.Body, depth + 1)
		elseif k == "Return" then
			line(depth, "Return"..at)
			for _, v in ipairs(s.Values) do dumpExpr(v, depth + 1) end
		elseif k == "TypeAlias" then
			line(depth, sfmt("TypeAlias %s%s = %s%s", s.Exported and "export " or "", s.Name, short(s.Type, 50), at))
		else
			line(depth, k..at)
		end
		if s.NotLast then line(depth, "  ^ warning: statement after "..k:lower().." is unreachable") end
	end

	dumpBlock = function(stmts, depth)
		line(depth, sfmt("Block (%d)", #stmts))
		for _, s in ipairs(stmts) do dumpStmt(s, depth + 1) end
	end

	out[#out+1] = "-- Script Analyzer :: Abstract Syntax Tree"
	out[#out+1] = sfmt("-- %d lines, %d tokens, %d functions, %d locals, %d distinct globals", ast.LineCount, ast.TokenCount,
		#ast.Functions, ast.LocalCount or 0, (function() local n = 0 for _ in pairs(ast.Globals or {}) do n += 1 end return n end)())
	out[#out+1] = ""
	out[#out+1] = "Chunk"
	dumpBlock(ast.Body, 1)
	return concat(out, "\n")
end

---------------------------------------------------------------------------------------------------
-- Source pipeline: extraction and statement level CFG
---------------------------------------------------------------------------------------------------
Core.ExtractSource = function(ast)
	local strings, seenStr, services, requires, calls, urls = {}, {}, {}, {}, {}, {}
	local function walk(node)
		if type(node) ~= "table" then return end
		local k = node.Kind
		if k == "String" then
			local v = decodeString(node.Raw)
			if not seenStr[v] then
				seenStr[v] = true
				strings[#strings+1] = {v, node.Line}
				for url in v:gmatch("[%w]+://[%w%-%._~:/%?#%[%]@!%$&'%(%)%*%+,;=%%]+") do urls[#urls+1] = url end
				for id in v:gmatch("rbxassetid://%d+") do urls[#urls+1] = id end
			end
		elseif k == "MethodCall" then
			local arg = node.Args[1]
			local argText = arg and short(Gen.expr(arg, 0), 50) or ""
			if node.Method == "GetService" or node.Method == "FindService" then
				services[#services+1] = sfmt("%-28s line %d", argText, node.Line)
			elseif INTERESTING_METHODS[node.Method] then
				calls[#calls+1] = sfmt("%-8s %s:%s(%s)  line %d", INTERESTING_METHODS[node.Method], short(Gen.expr(node.Obj, 0), 40), node.Method, argText, node.Line)
			end
		elseif k == "Call" and node.Func.Kind == "Name" and node.Func.Name == "require" then
			requires[#requires+1] = sfmt("%-40s line %d", node.Args[1] and short(Gen.expr(node.Args[1], 0), 60) or "?", node.Line)
		elseif k == "Call" and node.Func.Kind == "Name" and (node.Func.Name == "loadstring" or node.Func.Name == "getfenv" or node.Func.Name == "setfenv") then
			calls[#calls+1] = sfmt("%-8s %s(...)  line %d", "dynamic", node.Func.Name, node.Line)
		end
		for key, v in pairs(node) do
			if type(v) == "table" and key ~= "Parent" then walk(v) end
		end
	end
	walk(ast.Body)
	table.sort(strings, function(a, b) return a[2] < b[2] end)
	return {Strings = strings, Services = services, Requires = requires, Calls = calls, Urls = urls}
end

Core.ReportSourceExtraction = function(ast)
	local out = {"-- Script Analyzer :: Extraction (source)"}
	local function add(s) out[#out+1] = s end
	local ex = Core.ExtractSource(ast)
	local globals = sortedCounts(ast.Globals)
	add(sfmt("-- %d lines, %d tokens, %d functions, %d locals, %d distinct globals", ast.LineCount, ast.TokenCount, #ast.Functions, ast.LocalCount, #globals))
	add("")
	local function section(title, list, fmt)
		add("--[[ "..title.." ("..#list..") ]]")
		if #list == 0 then add("\t(none)") end
		for _, v in ipairs(list) do add("\t"..(fmt and fmt(v) or v)) end
		add("")
	end
	section("Services", ex.Services)
	section("require()", ex.Requires)
	section("Globals (free names)", globals, function(v) return sfmt("%-28s x%d", v[1], v[2]) end)
	section("Remote / network / http / dynamic calls", ex.Calls)
	section("URLs and asset ids", ex.Urls)
	section("Functions", ast.Functions, function(fn)
		local params = {}
		for j, prm in ipairs(fn.Params) do params[j] = prm.Name end
		if fn.Vararg and not fn.IsMain then params[#params+1] = "..." end
		return sfmt("%-36s (%s)  lines %d-%d", fn.Name or "<anonymous>", concat(params, ", "), fn.Line, fn.EndLine or fn.Line)
	end)
	section("String literals", ex.Strings, function(v) return sfmt("line %-5d %s", v[2], quote(#v[1] > 200 and (v[1]:sub(1, 200).."...") or v[1])) end)
	return concat(out, "\n")
end

local function stmtSummary(s)
	local ok, text = pcall(Gen.stmt, s, 0)
	text = ok and text or s.Kind
	return sfmt("%4d  %s", s.Line or 0, short(text:match("^[^\n]*"), 90))
end

Core.BuildSourceGraph = function(fn)
	local g = newGraph(sfmt("function %s (%s)  [lines %d-%d]", fn.Name or "<anonymous>", fn.IsMain and "chunk" or (#fn.Params.." params"), fn.Line, fn.EndLine or fn.Line))
	local cur = addBlock(g, "entry")
	local loops = {}

	local walk
	local function fresh(label)
		return addBlock(g, label)
	end
	walk = function(stmts)
		for _, s in ipairs(stmts) do
			local k = s.Kind
			if k == "If" then
				local test = cur
				local ends = {}
				for j, c in ipairs(s.Clauses) do
					test.Lines[#test.Lines+1] = sfmt("%4d  %s %s then", c.Cond.Line or s.Line, j == 1 and "if" or "elseif", short(Gen.expr(c.Cond, 0), 70))
					local body = fresh("then")
					addEdge(test, body, "true")
					cur = body
					walk(c.Body)
					ends[#ends+1] = cur
					if j < #s.Clauses or s.Else then
						local nextTest = fresh(j < #s.Clauses and "elseif" or "else")
						addEdge(test, nextTest, "false")
						test = nextTest
					end
				end
				if s.Else then
					cur = test
					walk(s.Else)
					ends[#ends+1] = cur
				else
					ends[#ends+1] = {FalseFrom = test}
				end
				local after = fresh("endif")
				for _, e in ipairs(ends) do
					if e.FalseFrom then addEdge(e.FalseFrom, after, "false")
					elseif not e.Dead then addEdge(e, after) end
				end
				cur = after
			elseif k == "While" or k == "NumericFor" or k == "GenericFor" then
				local header = fresh(k == "While" and "while" or "for")
				addEdge(cur, header)
				if k == "While" then header.Lines[#header.Lines+1] = sfmt("%4d  while %s do", s.Line, short(Gen.expr(s.Cond, 0), 70))
				else header.Lines[#header.Lines+1] = stmtSummary(s) end
				local body = fresh("loop body")
				addEdge(header, body, "true")
				loops[#loops+1] = {Continue = header, Exits = {}}
				cur = body
				walk(s.Body)
				if not cur.Dead then addEdge(cur, header, "loop") end
				local info = table.remove(loops)
				local after = fresh("end loop")
				addEdge(header, after, "false")
				for _, b in ipairs(info.Exits) do addEdge(b, after, "break") end
				cur = after
			elseif k == "Repeat" then
				local body = fresh("repeat")
				addEdge(cur, body)
				loops[#loops+1] = {ContinueLater = true, Exits = {}, Conts = {}}
				cur = body
				walk(s.Body)
				local info = table.remove(loops)
				local test = fresh("until")
				test.Lines[#test.Lines+1] = sfmt("%4d  until %s", s.Cond.Line or s.Line, short(Gen.expr(s.Cond, 0), 70))
				if not cur.Dead then addEdge(cur, test) end
				for _, b in ipairs(info.Conts) do addEdge(b, test, "continue") end
				addEdge(test, body, "loop")
				local after = fresh("end repeat")
				addEdge(test, after, "true")
				for _, b in ipairs(info.Exits) do addEdge(b, after, "break") end
				cur = after
			elseif k == "Do" then
				walk(s.Body)
			elseif k == "Return" or k == "Break" or k == "Continue" then
				cur.Lines[#cur.Lines+1] = stmtSummary(s)
				local loop = loops[#loops]
				if k == "Return" then
					cur.Returns = true
				elseif loop then
					if k == "Break" then loop.Exits[#loop.Exits+1] = cur
					elseif loop.ContinueLater then loop.Conts[#loop.Conts+1] = cur
					else addEdge(cur, loop.Continue, "continue") end
				end
				local dead = fresh("after "..k:lower())
				dead.Dead = true
				cur = dead
			else
				cur.Lines[#cur.Lines+1] = stmtSummary(s)
			end
		end
	end
	walk(fn.Body)
	analyzeGraph(g)
	local warnings = {}
	for _, b in ipairs(g.Blocks) do
		if not b.Reachable and #b.Lines > 0 then
			warnings[#warnings+1] = sfmt("unreachable code in B%d: %s", b.Id, b.Lines[1])
		end
	end
	-- Hide dead blocks that carry no statements, they only exist as placeholders after jumps
	local kept = {}
	for _, b in ipairs(g.Blocks) do
		if b.Reachable or #b.Lines > 0 then kept[#kept+1] = b end
	end
	for j, b in ipairs(kept) do b.Id = j - 1 end
	for _, b in ipairs(kept) do
		local pred = {}
		for _, p in ipairs(b.Pred) do if table.find(kept, p) then pred[#pred+1] = p end end
		b.Pred = pred
	end
	g.Blocks = kept
	analyzeGraph(g)
	for _, l in ipairs(g.Loops) do l.Kind = l.Header.Label end
	g.Warnings = warnings
	return g
end

Core.ReportSourceCFA = function(ast)
	local out = {"-- Script Analyzer :: Control Flow Analysis (source)",
		"-- Statement level graph per function; '*' marks a back edge (loop).", ""}
	for _, fn in ipairs(ast.Functions) do
		local g = Core.BuildSourceGraph(fn)
		renderGraph(g, out)
		for _, w in ipairs(g.Warnings) do insert(out, #out, "\t-- warning: "..w) end
	end
	return concat(out, "\n")
end

-- Runs every stage that applies and returns the four report texts
Core.AnalyzeBytecode = function(bytecode, source)
	local chunk = Core.Decode(Core.Deserialize(bytecode))
	local result = {Chunk = chunk}
	if chunk.CompileError then
		local msg = "-- Bytecode contains a compile error:\n--[[\n"..chunk.CompileError.."\n]]"
		result.Extraction, result.CFA, result.AST, result.CodeGen = msg, msg, msg, msg
		return result
	end
	result.Extraction = Core.ReportExtraction(chunk)
	result.CFA = Core.ReportBytecodeCFA(chunk)
	result.CodeGen = Core.ReportBytecodeCodegen(chunk)
	if source and source ~= "" then
		local ok, ast = pcall(function() return Core.Resolve(Core.Parse(source)) end)
		result.AST = ok and Core.DumpAST(ast) or ("-- Could not parse the decompiled source:\n-- "..tostring(ast))
	else
		result.AST = "-- An AST is built from source text. No decompiled source is available for this script,\n"
			.."-- paste source into the Input tab and switch to Source mode, or see Code Gen for the lifted bytecode."
	end
	return result
end

Core.AnalyzeSource = function(source)
	local ast = Core.Resolve(Core.Parse(source))
	return {
		Ast = ast,
		Extraction = Core.ReportSourceExtraction(ast),
		CFA = Core.ReportSourceCFA(ast),
		AST = Core.DumpAST(ast),
		CodeGen = "-- Script Analyzer :: Code Generation (regenerated from the AST)\n-- Normalized formatting; comments are not part of the AST and are dropped.\n\n"..Core.Generate(ast),
	}
end

---------------------------------------------------------------------------------------------------
-- App
---------------------------------------------------------------------------------------------------
local function main()
	local ScriptAnalyzer = {}
	ScriptAnalyzer.Core = Core

	local window, codeFrame, targetLabel, modeButton
	local tabButtons = {}
	local TABS = {"Input", "Extraction", "CFA", "AST", "Code Gen"}
	local TAB_KEYS = {Input = "Input", Extraction = "Extraction", CFA = "CFA", AST = "AST", ["Code Gen"] = "CodeGen"}
	local state = {Mode = "Bytecode", Tab = "Input", Input = "", Results = {}, Target = nil}

	local function getPath(obj)
		local ok, path = pcall(function() return Explorer.GetInstancePath(obj) end)
		return ok and path or obj:GetFullName()
	end

	local function refreshTabs()
		local theme = Settings.Theme
		for name, btn in pairs(tabButtons) do
			local active = name == state.Tab
			btn.TextColor3 = active and theme.Text or Color3.fromRGB(150, 152, 165)
			btn.Underline.Visible = active
		end
		modeButton.Text = "Mode: "..state.Mode
		if state.Target then
			targetLabel.Text = getPath(state.Target)
		else
			targetLabel.Text = state.Mode == "Bytecode" and "No script, use Explorer > Analyze Script" or "Paste source in Input"
		end
	end

	local function showTab(name)
		if state.Tab == "Input" then state.Input = codeFrame:GetText() end
		state.Tab = name
		if name == "Input" then
			codeFrame.Editable = true
			codeFrame:SetText(state.Input)
		else
			codeFrame.Editable = false
			codeFrame:SetText(state.Results[TAB_KEYS[name]] or "-- Press Analyze to run this stage.")
		end
		refreshTabs()
	end

	local function setResults(results)
		state.Results = results
		if state.Tab == "Input" then showTab("Extraction") else showTab(state.Tab) end
	end

	local function fail(msg)
		local text = "-- Analysis failed:\n-- "..tostring(msg)
		setResults({Extraction = text, CFA = text, AST = text, CodeGen = text})
	end

	ScriptAnalyzer.Run = function()
		if state.Tab == "Input" then state.Input = codeFrame:GetText() end
		window:SetTitle("Script Analyzer - Working...")
		task.spawn(function()
			local ok, err = pcall(function()
				if state.Mode == "Bytecode" then
					if not state.Target then error("no script selected; right click a script in Explorer > Analyze Script", 0) end
					if not env.getscriptbytecode then error("your executor has no getscriptbytecode, use Source mode", 0) end
					local gotBytecode, bytecode = pcall(env.getscriptbytecode, state.Target)
					if not gotBytecode or type(bytecode) ~= "string" or bytecode == "" then
						error("getscriptbytecode returned nothing (server script, or not loaded on the client)", 0)
					end
					setResults(Core.AnalyzeBytecode(bytecode, state.Input))
				else
					if state.Input:gsub("%s", "") == "" then error("the Input tab is empty", 0) end
					setResults(Core.AnalyzeSource(state.Input))
				end
			end)
			if not ok then fail(err) end
			window:SetTitle("Script Analyzer")
		end)
	end

	ScriptAnalyzer.Analyze = function(scr)
		state.Target = scr
		state.Mode = env.getscriptbytecode and "Bytecode" or "Source"
		state.Input = ""
		window:Show()
		showTab("Input")
		codeFrame:SetText("-- Decompiling for the AST stage...")
		task.spawn(function()
			local ok, source = pcall(env.decompile or function() end, scr)
			-- the decompiler falls back to this module's own bytecode lift, which is not parseable Luau
			local lifted = tostring(env.LastDecompiler or ""):find("bytecode lift", 1, true)
			if ok and type(source) == "string" and not lifted and not source:match("^%s*%-%- ?[Ff]ailed") and not source:match("^%-%- Error") and not source:match("^Failed") then
				state.Input = (Main.DecompileHeader or "")..source
			else
				state.Input = ""
			end
			if state.Tab == "Input" then codeFrame:SetText(state.Input) end
			ScriptAnalyzer.Run()
		end)
	end

	ScriptAnalyzer.Init = function()
		window = Lib.Window.new()
		window:SetTitle("Script Analyzer")
		window:Resize(640, 460)
		ScriptAnalyzer.Window = window
		local content = window.GuiElems.Content

		local function makeButton(text, pos, size, parent)
			local b = Instance.new("TextButton")
			b.BackgroundTransparency = 1
			b.BorderSizePixel = 0
			b.Position = pos
			b.Size = size
			b.Text = text
			b.TextColor3 = Color3.new(1, 1, 1)
			b.TextSize = 14
			b.Font = Enum.Font.SourceSans
			b.Parent = parent or content
			Lib.SoftFlatButton(b)
			return b
		end

		-- Toolbar
		modeButton = makeButton("Mode: Bytecode", UDim2.new(0, 2, 0, 1), UDim2.new(0, 110, 0, 20))
		modeButton.MouseButton1Click:Connect(function()
			state.Mode = state.Mode == "Bytecode" and "Source" or "Bytecode"
			refreshTabs()
		end)

		targetLabel = Instance.new("TextLabel")
		targetLabel.BackgroundTransparency = 1
		targetLabel.Position = UDim2.new(0, 118, 0, 1)
		targetLabel.Size = UDim2.new(1, -330, 0, 20)
		targetLabel.Font = Enum.Font.SourceSans
		targetLabel.TextSize = 14
		targetLabel.TextColor3 = Color3.fromRGB(150, 152, 165)
		targetLabel.TextXAlignment = Enum.TextXAlignment.Left
		targetLabel.TextTruncate = Enum.TextTruncate.AtEnd
		targetLabel.Parent = content

		local analyze = makeButton("Analyze", UDim2.new(1, -208, 0, 1), UDim2.new(0, 66, 0, 20))
		analyze.MouseButton1Click:Connect(ScriptAnalyzer.Run)

		local copy = makeButton("Copy", UDim2.new(1, -140, 0, 1), UDim2.new(0, 66, 0, 20))
		if not env.setclipboard then copy.TextColor3 = Color3.new(0.5, 0.5, 0.5) end
		copy.MouseButton1Click:Connect(function()
			if env.setclipboard then env.setclipboard(codeFrame:GetText()) end
		end)

		local save = makeButton("Save", UDim2.new(1, -72, 0, 1), UDim2.new(0, 70, 0, 20))
		save.MouseButton1Click:Connect(function()
			local name = "Analysis_"..(state.Target and state.Target.Name or "source").."_"..state.Tab:gsub(" ", "").."_"..os.time()..".txt"
			Lib.SaveAsPrompt(name, codeFrame:GetText())
		end)

		-- Tabs
		local tabBar = Instance.new("Frame")
		tabBar.BackgroundTransparency = 1
		tabBar.Position = UDim2.new(0, 0, 0, 23)
		tabBar.Size = UDim2.new(1, 0, 0, 20)
		tabBar.Parent = content
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.Padding = UDim.new(0, 2)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = tabBar
		for j, name in ipairs(TABS) do
			local b = Instance.new("TextButton")
			b.BackgroundTransparency = 1
			b.BorderSizePixel = 0
			b.AutoButtonColor = false
			b.Size = UDim2.new(0, 90, 1, 0)
			b.Text = name
			b.TextSize = 14
			b.Font = Enum.Font.SourceSans
			b.LayoutOrder = j
			b.Parent = tabBar
			local underline = Instance.new("Frame")
			underline.Name = "Underline"
			underline.BorderSizePixel = 0
			underline.BackgroundColor3 = Settings.Theme.Accent
			underline.Position = UDim2.new(0, 8, 1, -2)
			underline.Size = UDim2.new(1, -16, 0, 2)
			underline.Visible = false
			underline.Parent = b
			b.MouseButton1Click:Connect(function() showTab(name) end)
			tabButtons[name] = b
		end

		codeFrame = Lib.CodeFrame.new()
		codeFrame.Frame.Position = UDim2.new(0, 0, 0, 45)
		codeFrame.Frame.Size = UDim2.new(1, 0, 1, -45)
		codeFrame.Frame.Parent = content
		codeFrame:SetText("-- Script Analyzer\n-- Bytecode mode: right click a script in Explorer > Analyze Script.\n-- Source mode: paste Luau source here, switch Mode to Source and press Analyze.\n")
		state.Input = codeFrame:GetText()

		refreshTabs()
	end

	return ScriptAnalyzer
end

-- TODO: Remove when open source
if gethsfuncs then
	_G.moduleData = {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main, Core = Core}
else
	return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main, Core = Core}
end
