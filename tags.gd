## Tags: reads music tags, length and bitrate straight from file headers (no decoding, no plugins).
## read(path) -> {title, artist, album, track, year: String, length: float s, bitrate: int kbps}
## plus art: PackedByteArray (jpg/png bytes) when want_art. Unknown/broken files give {}.
## Formats: MP3 (ID3v1/v2.2-2.4, Xing/VBRI/CBR length), FLAC, OGG Vorbis/Opus, WAV (INFO + id3), GameCube DSP.

const AUDIO := ["mp3", "flac", "ogg", "opus", "wav", "dsp"]
const ID3_KEYS := {
	"TIT2": "title", "TPE1": "artist", "TALB": "album", "TRCK": "track", "TYER": "year", "TDRC": "year",
	"TT2": "title", "TP1": "artist", "TAL": "album", "TRK": "track", "TYE": "year",
}
const VORBIS_KEYS := {"TITLE": "title", "ARTIST": "artist", "ALBUM": "album", "TRACKNUMBER": "track", "DATE": "year", "YEAR": "year"}
const INFO_KEYS := {"INAM": "title", "IART": "artist", "IPRD": "album", "ICRD": "year", "ITRK": "track", "IPRT": "track"}


static func read(path: String, want_art := false) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 12:
		return {}
	var out := {}
	match path.get_extension().to_lower():
		"mp3": _mp3(f, out, want_art)
		"flac": _flac(f, out, want_art)
		"ogg", "opus": _ogg(f, out, want_art)
		"wav": _wav(f, out, want_art)
		"dsp": _dsp(f, out)
	if out.has("length") and out.length > 0 and not out.has("bitrate"):
		out.bitrate = roundi(f.get_length() * 8.0 / out.length / 1000.0)
	for k in ["title", "artist", "album", "track", "year"]:
		if out.has(k):
			out[k] = str(out[k]).strip_edges()
			if k == "year":
				out.year = out.year.left(4)
			if out[k] == "":
				out.erase(k)
	return out


# --- helpers -----------------------------------------------------------------

# Every reader below is bounds-safe: damaged or truncated files read as 0, never as an error.
static func _be(b: PackedByteArray, i: int, n: int) -> int:
	if i < 0 or i + n > b.size():
		return 0
	var v := 0
	for k in n:
		v = (v << 8) | b[i + k]
	return v


static func _synchsafe(b: PackedByteArray, i: int) -> int:
	if i < 0 or i + 4 > b.size():
		return 0
	return (b[i] << 21) | (b[i + 1] << 14) | (b[i + 2] << 7) | b[i + 3]


static func _u32(b: PackedByteArray, i: int) -> int:
	return b.decode_u32(i) if i >= 0 and i + 4 <= b.size() else 0


static func _u16(b: PackedByteArray, i: int) -> int:
	return b.decode_u16(i) if i >= 0 and i + 2 <= b.size() else 0


## Bytes up to (not including) the first NUL; step 2 keeps UTF-16 code units aligned.
static func _cut(b: PackedByteArray, step := 1) -> PackedByteArray:
	for i in range(0, b.size() - step + 1, step):
		if b[i] == 0 and (step == 1 or b[i + 1] == 0):
			return b.slice(0, i)
	return b


static func _latin1(b: PackedByteArray) -> String:
	var s := ""
	for c in b:
		if c == 0:
			break
		s += String.chr(c)
	return s


## ID3 text: 0 latin-1, 1 UTF-16 with BOM, 2 UTF-16BE, 3 UTF-8. First value only (v2.4 separates with NUL).
static func _id3_text(b: PackedByteArray, enc: int) -> String:
	match enc:
		1, 2:
			var le := enc == 1 and b.size() >= 2 and b[0] == 0xFF and b[1] == 0xFE
			if enc == 1 and b.size() >= 2 and (b[0] == 0xFF or b[0] == 0xFE):
				b = b.slice(2)
			if not le:  # swap to little-endian for get_string_from_utf16
				b = b.duplicate()
				for i in range(0, b.size() - 1, 2):
					var t := b[i]; b[i] = b[i + 1]; b[i + 1] = t
			return _cut(b, 2).get_string_from_utf16()
		3:
			return _cut(b).get_string_from_utf8()
	return _latin1(b)


## Index just past a text terminator starting at i (1 NUL, or 2 aligned NULs for UTF-16).
static func _skip_term(b: PackedByteArray, i: int, enc: int) -> int:
	if enc == 1 or enc == 2:
		while i + 1 < b.size() and not (b[i] == 0 and b[i + 1] == 0):
			i += 2
		return i + 2
	while i < b.size() and b[i] != 0:
		i += 1
	return i + 1


# --- MP3 ---------------------------------------------------------------------

## Parses an ID3v2 tag at the file's current position. Returns the tag's end offset, or -1 if none.
static func _id3v2(f: FileAccess, out: Dictionary, want_art: bool) -> int:
	var start := f.get_position()
	var h := f.get_buffer(10)
	if h.size() < 10 or h.slice(0, 3).get_string_from_ascii() != "ID3":
		f.seek(start)
		return -1
	var ver := h[3]
	var flags := h[5]
	var end := start + 10 + _synchsafe(h, 6) + (10 if flags & 0x10 else 0)
	if flags & 0x40:  # extended header
		var e := f.get_buffer(4)
		f.seek(f.get_position() - 4 + (_synchsafe(e, 0) if ver == 4 else _be(e, 0, 4) + 4))
	var idlen := 3 if ver == 2 else 4
	end = mini(end, f.get_length())  # a damaged header can claim more than the file holds
	var fhlen := 6 if ver == 2 else 10
	while f.get_position() + idlen * 2 < end:
		var fh := f.get_buffer(fhlen)
		if fh.size() < fhlen or fh[0] == 0:
			break  # padding, or the file ends here
		var id := fh.slice(0, idlen).get_string_from_ascii()
		var size := _be(fh, 3, 3) if ver == 2 else (_synchsafe(fh, 4) if ver == 4 else _be(fh, 4, 4))
		var body_at := f.get_position()
		if size <= 0 or body_at + size > end:
			break
		var is_pic := id == "APIC" or id == "PIC"
		if ID3_KEYS.has(id) or (is_pic and want_art and not out.has("art")):
			var b := f.get_buffer(size)
			if ver == 4 and fh[9] & 0x01:  # data-length indicator
				b = b.slice(4)
			if b.is_empty():
				break
			if is_pic:
				var enc := b[0]
				var i := 4 if ver == 2 else _skip_term(b, 1, 0)  # v2.2: 3-char format; else MIME
				out.art = b.slice(_skip_term(b, i + 1, enc))  # +1 skips the picture type byte
			elif not out.has(ID3_KEYS[id]):
				out[ID3_KEYS[id]] = _id3_text(b.slice(1), b[0])
		f.seek(body_at + size)
	f.seek(end)
	return end


static func _mp3(f: FileAccess, out: Dictionary, want_art: bool) -> void:
	var audio_start := maxi(_id3v2(f, out, want_art), 0)
	var audio_end := f.get_length()
	f.seek(audio_end - 128)
	var v1 := f.get_buffer(128)
	if v1.size() == 128 and v1.slice(0, 3).get_string_from_ascii() == "TAG":
		audio_end -= 128
		for pair in [["title", 3], ["artist", 33], ["album", 63]]:
			if not out.has(pair[0]):
				out[pair[0]] = _latin1(v1.slice(pair[1], pair[1] + 30))
		if not out.has("year"):
			out.year = _latin1(v1.slice(93, 97))
		if not out.has("track") and v1[125] == 0 and v1[126] > 0:
			out.track = str(v1[126])
	# First valid MPEG frame header after the tag.
	f.seek(audio_start)
	var b := f.get_buffer(65536)
	for i in b.size() - 4:
		if b[i] != 0xFF or (b[i + 1] & 0xE0) != 0xE0:
			continue
		var ver := (b[i + 1] >> 3) & 3  # 3 = MPEG1, 2 = MPEG2, 0 = MPEG2.5
		var layer := (b[i + 1] >> 1) & 3  # 3 = I, 2 = II, 1 = III
		var bri := b[i + 2] >> 4
		var sri := (b[i + 2] >> 2) & 3
		if ver == 1 or layer == 0 or bri == 0 or bri == 15 or sri == 3:
			continue
		var mpeg1 := ver == 3
		var kbps: int = _bitrate_table(mpeg1, layer)[bri]
		var rate: int = [44100, 48000, 32000][sri] >> (0 if mpeg1 else (1 if ver == 2 else 2))
		var spf := 384 if layer == 3 else (1152 if mpeg1 or layer == 2 else 576)
		var mono := (b[i + 3] >> 6) == 3
		var xing := i + 4 + ((17 if mono else 32) if mpeg1 else (9 if mono else 17))
		var frames := 0
		var tag := b.slice(xing, xing + 4).get_string_from_ascii() if xing + 12 <= b.size() else ""
		if (tag == "Xing" or tag == "Info") and _be(b, xing + 4, 4) & 1:
			frames = _be(b, xing + 8, 4)
		elif i + 54 <= b.size() and b.slice(i + 36, i + 40).get_string_from_ascii() == "VBRI":
			frames = _be(b, i + 50, 4)
		var bytes := audio_end - (audio_start + i)
		if bytes <= 0:
			return
		if frames > 0:
			out.length = frames * spf / float(rate)
		else:
			out.length = bytes * 8.0 / (kbps * 1000.0)
		out.bitrate = roundi(bytes * 8.0 / out.length / 1000.0) if frames > 0 else kbps
		return


static func _bitrate_table(mpeg1: bool, layer: int) -> Array:
	if mpeg1:
		match layer:
			3: return [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448]
			2: return [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
			_: return [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
	if layer == 3:
		return [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256]
	return [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]


# --- FLAC / Vorbis comments --------------------------------------------------

static func _flac(f: FileAccess, out: Dictionary, want_art: bool) -> void:
	_id3v2(f, out, false)  # some rippers put an ID3 tag in front
	if f.get_buffer(4).get_string_from_ascii() != "fLaC":
		return
	var last := false
	while not last and f.get_position() + 4 <= f.get_length():
		var h := f.get_buffer(4)
		last = h[0] & 0x80 != 0
		var type := h[0] & 0x7F
		var size := _be(h, 1, 3)
		var at := f.get_position()
		if type == 0:
			var b := f.get_buffer(size)
			if b.size() < 18:
				return
			var rate := (b[10] << 12) | (b[11] << 4) | (b[12] >> 4)
			var total := ((b[13] & 0x0F) << 32) | _be(b, 14, 4)
			if rate > 0:
				out.length = total / float(rate)
		elif type == 4:
			_vorbis_comments(f.get_buffer(size), 0, out, want_art)
		elif type == 6 and want_art and not out.has("art"):
			out.art = _flac_picture(f.get_buffer(size))
		f.seek(at + size)


## Vorbis comment block (little-endian lengths) starting at byte i.
static func _vorbis_comments(b: PackedByteArray, i: int, out: Dictionary, want_art: bool) -> void:
	if i + 8 > b.size():
		return
	i += 4 + _u32(b, i)  # vendor string
	if i + 4 > b.size():
		return
	var count := _u32(b, i)
	i += 4
	for _k in count:
		if i + 4 > b.size():
			return
		var n := _u32(b, i)
		var kv := b.slice(i + 4, i + 4 + n).get_string_from_utf8()
		i += 4 + n
		var key := kv.get_slice("=", 0).to_upper()
		var val := kv.substr(key.length() + 1)
		if VORBIS_KEYS.has(key) and not out.has(VORBIS_KEYS[key]):
			out[VORBIS_KEYS[key]] = val
		elif key == "METADATA_BLOCK_PICTURE" and want_art and not out.has("art"):
			out.art = _flac_picture(Marshalls.base64_to_raw(val))


## FLAC PICTURE block (big-endian): type, mime, description, w, h, depth, colours, data.
static func _flac_picture(b: PackedByteArray) -> PackedByteArray:
	if b.size() < 32:
		return PackedByteArray()
	var i := 4
	i += 4 + _be(b, i, 4)  # MIME
	i += 4 + _be(b, i, 4)  # description
	i += 16
	return b.slice(i + 4, i + 4 + _be(b, i, 4))


# --- OGG (Vorbis, Opus) ------------------------------------------------------

static func _ogg(f: FileAccess, out: Dictionary, want_art: bool) -> void:
	# Reassemble the first two packets (identification + comments) from the page segments.
	var packets: Array[PackedByteArray] = [PackedByteArray()]
	while packets.size() <= 2 and f.get_position() + 27 <= f.get_length():
		var h := f.get_buffer(27)
		if h.slice(0, 4).get_string_from_ascii() != "OggS":
			return
		var segs := f.get_buffer(h[26])
		for s in segs:
			packets[-1].append_array(f.get_buffer(s))
			if s < 255:
				packets.append(PackedByteArray())
	var id := packets[0]
	var rate := 0
	var preskip := 0
	if id.slice(0, 7) == PackedByteArray([1]) + "vorbis".to_ascii_buffer():
		rate = _u32(id, 12)
		if packets.size() > 1:
			_vorbis_comments(packets[1], 7, out, want_art)
	elif id.slice(0, 8).get_string_from_ascii() == "OpusHead":
		rate = 48000  # Opus granule positions always count 48 kHz samples
		preskip = _u16(id, 10)
		if packets.size() > 1:
			_vorbis_comments(packets[1], 8, out, want_art)
	if rate == 0:
		return
	# Length = last page's granule position.
	var n := mini(f.get_length(), 65536)
	f.seek(f.get_length() - n)
	var tail := f.get_buffer(n)
	var at := tail.size() - 14
	while at >= 0:
		if tail[at] == 0x4F and tail.slice(at, at + 4).get_string_from_ascii() == "OggS":
			out.length = maxf(tail.decode_s64(at + 6) - preskip, 0) / float(rate)
			return
		at -= 1


# --- WAV / DSP ---------------------------------------------------------------

static func _wav(f: FileAccess, out: Dictionary, want_art: bool) -> void:
	var h := f.get_buffer(12)
	if h.slice(0, 4).get_string_from_ascii() != "RIFF" or h.slice(8, 12).get_string_from_ascii() != "WAVE":
		return
	var byterate := 0
	var data := 0
	while f.get_position() + 8 <= f.get_length():
		var c := f.get_buffer(8)
		var id := c.slice(0, 4).get_string_from_ascii()
		var at := f.get_position()
		var size := mini(c.decode_u32(4), f.get_length() - at)  # never trust a size past the end of the file
		match id:
			"fmt ":
				byterate = _u32(f.get_buffer(12), 8)
			"data":
				data = size
			"LIST":
				var b := f.get_buffer(size)
				if b.slice(0, 4).get_string_from_ascii() == "INFO":
					var i := 4
					while i + 8 <= b.size():
						var sid := b.slice(i, i + 4).get_string_from_ascii()
						var slen := _u32(b, i + 4)
						if INFO_KEYS.has(sid) and not out.has(INFO_KEYS[sid]):
							out[INFO_KEYS[sid]] = _cut(b.slice(i + 8, i + 8 + slen)).get_string_from_utf8()
						i += 8 + slen + (slen & 1)
			"id3 ", "ID3 ":
				_id3v2(f, out, want_art)
		f.seek(at + size + (size & 1))
	if byterate > 0 and data > 0:
		out.length = data / float(byterate)
		out.bitrate = roundi(byterate * 8 / 1000.0)


## Nintendo GameCube/Wii DSP ADPCM: big-endian sample count and rate in the header.
static func _dsp(f: FileAccess, out: Dictionary) -> void:
	var b := f.get_buffer(12)
	var samples := _be(b, 0, 4)
	var rate := _be(b, 8, 4)
	if rate >= 4000 and rate <= 96000 and samples > 0:
		out.length = samples / float(rate)
