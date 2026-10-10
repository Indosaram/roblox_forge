--!strict
-- Pixels: pure-Luau RGBA raster canvas. No Roblox APIs and no math.random, so
-- it runs under Lune for specs and CLI previews and on the Roblox client for
-- EditableImage. Channels are stored 0..1 in a flat row-major array
-- (index = (y * width + x) * 4 + channel) and every drawing primitive
-- alpha-blends source-over, so callers can layer shapes.
--
-- Colors accept two forms, matching the two JSON/YAML serializations in the
-- repo: a table { r, g, b, a? } with channels 0..1 (MeshBuilder/ProcAssets), or
-- a [r, g, b] array with channels 0..255 (games/<pack>/assets/procgen.yml).

export type Color = { r: number, g: number, b: number, a: number? }

export type Canvas = {
	width: number,
	height: number,
	data: { number },
	set: (self: Canvas, x: number, y: number, color: any) -> (),
	get: (self: Canvas, x: number, y: number) -> (number, number, number, number),
	blend: (self: Canvas, x: number, y: number, color: any, coverage: number?) -> (),
	fill: (self: Canvas, color: any) -> (),
	circle: (self: Canvas, cx: number, cy: number, radius: number, color: any, soft: boolean?) -> (),
	ring: (self: Canvas, cx: number, cy: number, radius: number, color: any, thickness: number?) -> (),
	rect: (self: Canvas, x: number, y: number, width: number, height: number, color: any) -> (),
	roundRect: (
		self: Canvas,
		x: number,
		y: number,
		width: number,
		height: number,
		radius: number,
		color: any
	) -> (),
	linearGradient: (
		self: Canvas,
		x: number,
		y: number,
		width: number,
		height: number,
		colorA: any,
		colorB: any,
		direction: string?
	) -> (),
	noise: (self: Canvas, seed: number, scale: number, colorA: any, colorB: any) -> (),
	stripes: (self: Canvas, colorA: any, colorB: any, width: number, direction: string?) -> (),
	blit: (self: Canvas, other: Canvas, x: number, y: number) -> (),
	toBuffer: (self: Canvas) -> buffer,
	toPPM: (self: Canvas) -> string,
}

local Pixels = {}

local function clamp01(value: number): number
	if value ~= value then
		return 0
	end
	return math.clamp(value, 0, 1)
end

--- Normalizes any accepted color into a { r, g, b, a } table with 0..1
--- channels. A table carrying an `r` field is read as 0..1; a 3-element array
--- is read as 0..255 (procgen.yml convention).
function Pixels.toColor(color: any): Color
	if typeof(color) ~= "table" then
		return { r = 1, g = 1, b = 1, a = 1 }
	end
	if color.r ~= nil then
		return {
			r = clamp01(color.r),
			g = clamp01(color.g),
			b = clamp01(color.b),
			a = if color.a ~= nil then clamp01(color.a) else 1,
		}
	end
	return {
		r = clamp01((color[1] or 0) / 255),
		g = clamp01((color[2] or 0) / 255),
		b = clamp01((color[3] or 0) / 255),
		a = 1,
	}
end

local function channels(color: any): (number, number, number, number)
	local c = Pixels.toColor(color)
	return c.r, c.g, c.b, c.a or 1
end

--- Linear interpolation between two colors (alpha included).
function Pixels.mix(colorA: any, colorB: any, t: number): Color
	local ar, ag, ab, aa = channels(colorA)
	local br, bg, bb, ba = channels(colorB)
	local k = math.clamp(t, 0, 1)
	return {
		r = ar + (br - ar) * k,
		g = ag + (bg - ag) * k,
		b = ab + (bb - ab) * k,
		a = aa + (ba - aa) * k,
	}
end

--- Deterministic MINSTD linear congruential generator (same constants as
--- MeshBuilder.rng), so texture/icon noise never depends on math.random.
function Pixels.rng(seed: number): () -> number
	local state = seed % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	return function(): number
		state = (48271 * state) % 2147483647
		return state / 2147483647
	end
end

-- Hashes one integer lattice point to 0..1. Everything stays below 2^53 so the
-- result is exact on every Luau runtime.
local function hash2(x: number, y: number, seed: number): number
	local state = (x * 73856093 + y * 19349663 + seed) % 2147483647
	state = (state * 48271) % 2147483647
	state = (state * 48271) % 2147483647
	return state / 2147483647
end

-- Value noise with a wrapping lattice: lattice index is taken modulo the
-- period, so a canvas whose dimensions are an exact multiple of `scale` tiles.
local function valueNoise(x: number, y: number, scale: number, seed: number, periodX: number, periodY: number): number
	local u = x / scale
	local v = y / scale
	local x0 = math.floor(u)
	local y0 = math.floor(v)
	local fx = u - x0
	local fy = v - y0
	local sx = fx * fx * (3 - 2 * fx)
	local sy = fy * fy * (3 - 2 * fy)
	local x0w = x0 % periodX
	local x1w = (x0 + 1) % periodX
	local y0w = y0 % periodY
	local y1w = (y0 + 1) % periodY
	local n00 = hash2(x0w, y0w, seed)
	local n10 = hash2(x1w, y0w, seed)
	local n01 = hash2(x0w, y1w, seed)
	local n11 = hash2(x1w, y1w, seed)
	local nx0 = n00 + (n10 - n00) * sx
	local nx1 = n01 + (n11 - n01) * sx
	return nx0 + (nx1 - nx0) * sy
end

function Pixels.new(width: number, height: number): Canvas
	if type(width) ~= "number" or width % 1 ~= 0 or width < 1 then
		error("invalid width")
	end
	if type(height) ~= "number" or height % 1 ~= 0 or height < 1 then
		error("invalid height")
	end
	local canvas = setmetatable({
		width = width,
		height = height,
		data = table.create(width * height * 4, 0),
	}, { __index = Pixels })
	return (canvas :: any) :: Canvas
end

--- Writes a pixel without blending, replacing its channels (including alpha).
function Pixels.set(self: Canvas, x: number, y: number, color: any): ()
	local px = math.floor(x)
	local py = math.floor(y)
	if px < 0 or py < 0 or px >= self.width or py >= self.height then
		return
	end
	local r, g, b, a = channels(color)
	local i = (py * self.width + px) * 4 + 1
	self.data[i] = r
	self.data[i + 1] = g
	self.data[i + 2] = b
	self.data[i + 3] = a
end

--- Reads a pixel's channels; out-of-bounds reads return transparent black.
function Pixels.get(self: Canvas, x: number, y: number): (number, number, number, number)
	local px = math.floor(x)
	local py = math.floor(y)
	if px < 0 or py < 0 or px >= self.width or py >= self.height then
		return 0, 0, 0, 0
	end
	local i = (py * self.width + px) * 4 + 1
	return self.data[i], self.data[i + 1], self.data[i + 2], self.data[i + 3]
end

--- Source-over blend of `color` (optionally scaled by `coverage` 0..1) onto a
--- pixel. The low-level primitive every shape uses and the hook custom
--- per-pixel art needs.
function Pixels.blend(self: Canvas, x: number, y: number, color: any, coverage: number?): ()
	local px = math.floor(x)
	local py = math.floor(y)
	if px < 0 or py < 0 or px >= self.width or py >= self.height then
		return
	end
	local cr, cg, cb, ca = channels(color)
	local alpha = ca * (if coverage == nil then 1 else math.clamp(coverage, 0, 1))
	if alpha <= 0 then
		return
	end
	local i = (py * self.width + px) * 4 + 1
	local d = self.data
	local dstA = d[i + 3]
	local outA = alpha + dstA * (1 - alpha)
	if outA <= 0 then
		d[i] = 0
		d[i + 1] = 0
		d[i + 2] = 0
		d[i + 3] = 0
		return
	end
	d[i] = (cr * alpha + d[i] * dstA * (1 - alpha)) / outA
	d[i + 1] = (cg * alpha + d[i + 1] * dstA * (1 - alpha)) / outA
	d[i + 2] = (cb * alpha + d[i + 2] * dstA * (1 - alpha)) / outA
	d[i + 3] = outA
end

function Pixels.fill(self: Canvas, color: any): ()
	local r, g, b, a = channels(color)
	local d = self.data
	for i = 1, self.width * self.height * 4, 4 do
		d[i] = r
		d[i + 1] = g
		d[i + 2] = b
		d[i + 3] = a
	end
end

function Pixels.circle(self: Canvas, cx: number, cy: number, radius: number, color: any, soft: boolean?): ()
	if radius <= 0 then
		return
	end
	local antialias = soft ~= false
	local minX = math.max(0, math.floor(cx - radius - 1))
	local maxX = math.min(self.width - 1, math.ceil(cx + radius + 1))
	local minY = math.max(0, math.floor(cy - radius - 1))
	local maxY = math.min(self.height - 1, math.ceil(cy + radius + 1))
	for py = minY, maxY do
		local dy = py + 0.5 - cy
		for px = minX, maxX do
			local dx = px + 0.5 - cx
			local dist = math.sqrt(dx * dx + dy * dy)
			local coverage
			if antialias then
				coverage = math.clamp(radius + 0.5 - dist, 0, 1)
			else
				coverage = if dist <= radius then 1 else 0
			end
			if coverage > 0 then
				self:blend(px, py, color, coverage)
			end
		end
	end
end

function Pixels.ring(self: Canvas, cx: number, cy: number, radius: number, color: any, thickness: number?): ()
	local band = thickness or math.max(1, radius * 0.25)
	if band <= 0 or radius <= 0 then
		return
	end
	local half = band / 2
	local minX = math.max(0, math.floor(cx - radius - half - 1))
	local maxX = math.min(self.width - 1, math.ceil(cx + radius + half + 1))
	local minY = math.max(0, math.floor(cy - radius - half - 1))
	local maxY = math.min(self.height - 1, math.ceil(cy + radius + half + 1))
	for py = minY, maxY do
		local dy = py + 0.5 - cy
		for px = minX, maxX do
			local dx = px + 0.5 - cx
			local dist = math.sqrt(dx * dx + dy * dy)
			local coverage = math.clamp(half + 0.5 - math.abs(dist - radius), 0, 1)
			if coverage > 0 then
				self:blend(px, py, color, coverage)
			end
		end
	end
end

function Pixels.rect(self: Canvas, x: number, y: number, width: number, height: number, color: any): ()
	if width <= 0 or height <= 0 then
		return
	end
	local x0 = math.max(0, math.floor(x))
	local y0 = math.max(0, math.floor(y))
	local x1 = math.min(self.width - 1, math.floor(x + width - 1))
	local y1 = math.min(self.height - 1, math.floor(y + height - 1))
	for py = y0, y1 do
		for px = x0, x1 do
			self:blend(px, py, color)
		end
	end
end

function Pixels.roundRect(
	self: Canvas,
	x: number,
	y: number,
	width: number,
	height: number,
	radius: number,
	color: any
): ()
	if width <= 0 or height <= 0 then
		return
	end
	local halfW = width / 2
	local halfH = height / 2
	local cornerRadius = math.clamp(radius, 0, math.min(halfW, halfH))
	local centerX = x + halfW
	local centerY = y + halfH
	local minX = math.max(0, math.floor(x - 1))
	local maxX = math.min(self.width - 1, math.ceil(x + width + 1))
	local minY = math.max(0, math.floor(y - 1))
	local maxY = math.min(self.height - 1, math.ceil(y + height + 1))
	for py = minY, maxY do
		local dy = math.abs(py + 0.5 - centerY) - (halfH - cornerRadius)
		for px = minX, maxX do
			local dx = math.abs(px + 0.5 - centerX) - (halfW - cornerRadius)
			local qx = math.max(dx, 0)
			local qy = math.max(dy, 0)
			local signed = math.sqrt(qx * qx + qy * qy) + math.min(math.max(dx, dy), 0) - cornerRadius
			local coverage = math.clamp(0.5 - signed, 0, 1)
			if coverage > 0 then
				self:blend(px, py, color, coverage)
			end
		end
	end
end

function Pixels.linearGradient(
	self: Canvas,
	x: number,
	y: number,
	width: number,
	height: number,
	colorA: any,
	colorB: any,
	direction: string?
): ()
	if width <= 0 or height <= 0 then
		return
	end
	local axis = direction or "vertical"
	local minX = math.max(0, math.floor(x))
	local maxX = math.min(self.width - 1, math.ceil(x + width) - 1)
	local minY = math.max(0, math.floor(y))
	local maxY = math.min(self.height - 1, math.ceil(y + height) - 1)
	for py = minY, maxY do
		for px = minX, maxX do
			local t
			if axis == "horizontal" then
				t = (px + 0.5 - x) / width
			elseif axis == "diagonal" then
				t = ((px + 0.5 - x) / width + (py + 0.5 - y) / height) / 2
			else
				t = (py + 0.5 - y) / height
			end
			self:blend(px, py, Pixels.mix(colorA, colorB, t))
		end
	end
end

function Pixels.noise(self: Canvas, seed: number, scale: number, colorA: any, colorB: any): ()
	local step = math.max(1, scale)
	local periodX = math.max(1, math.floor(self.width / step + 0.5))
	local periodY = math.max(1, math.floor(self.height / step + 0.5))
	for py = 0, self.height - 1 do
		for px = 0, self.width - 1 do
			local t = valueNoise(px, py, step, seed, periodX, periodY)
			self:blend(px, py, Pixels.mix(colorA, colorB, t))
		end
	end
end

function Pixels.stripes(self: Canvas, colorA: any, colorB: any, width: number, direction: string?): ()
	local band = math.max(1, width)
	local axis = direction or "vertical"
	for py = 0, self.height - 1 do
		for px = 0, self.width - 1 do
			local coord
			if axis == "horizontal" then
				coord = py
			elseif axis == "diagonal" then
				coord = px + py
			else
				coord = px
			end
			local index = math.floor(coord / band) % 2
			self:blend(px, py, if index == 0 then colorA else colorB)
		end
	end
end

function Pixels.blit(self: Canvas, other: Canvas, x: number, y: number): ()
	local ox = math.floor(x)
	local oy = math.floor(y)
	for sy = 0, other.height - 1 do
		for sx = 0, other.width - 1 do
			local i = (sy * other.width + sx) * 4 + 1
			local a = other.data[i + 3]
			if a > 0 then
				self:blend(ox + sx, oy + sy, { r = other.data[i], g = other.data[i + 1], b = other.data[i + 2], a = a })
			end
		end
	end
end

local function toByte(value: number): number
	return math.clamp(math.floor(value * 255 + 0.5), 0, 255)
end

--- Packs the canvas as an RGBA8 buffer (width * height * 4 bytes) for
--- AssetService:CreateEditableImage + EditableImage:WritePixelsBuffer.
function Pixels.toBuffer(self: Canvas): buffer
	local buf = buffer.create(self.width * self.height * 4)
	local d = self.data
	local count = self.width * self.height
	for i = 0, count - 1 do
		buffer.writeu8(buf, i * 4, toByte(d[i * 4 + 1]))
		buffer.writeu8(buf, i * 4 + 1, toByte(d[i * 4 + 2]))
		buffer.writeu8(buf, i * 4 + 2, toByte(d[i * 4 + 3]))
		buffer.writeu8(buf, i * 4 + 3, toByte(d[i * 4 + 4]))
	end
	return buf
end

--- Encodes the canvas as a binary PPM (P6) image so Lune specs and the CLI can
--- dump human-viewable previews without any image library.
function Pixels.toPPM(self: Canvas): string
	local header = string.format("P6\n%d %d\n255\n", self.width, self.height)
	local buf = buffer.create(#header + self.width * self.height * 3)
	for i = 1, #header do
		buffer.writeu8(buf, i - 1, string.byte(header, i))
	end
	local offset = #header
	local d = self.data
	local count = self.width * self.height
	for i = 0, count - 1 do
		buffer.writeu8(buf, offset, toByte(d[i * 4 + 1]))
		buffer.writeu8(buf, offset + 1, toByte(d[i * 4 + 2]))
		buffer.writeu8(buf, offset + 2, toByte(d[i * 4 + 3]))
		offset += 3
	end
	return buffer.tostring(buf)
end

return Pixels
