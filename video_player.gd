extends Node
## Plays any video ffmpeg can read (MP4, MKV, WebM, MOV, AVI...). Two ffmpeg processes stream
## raw frames and raw sound through pipes (no temp files); a clock keeps them in step, and frames
## that arrive late are skipped rather than slowing playback down.

signal finished

const FPS := 30

var target: TextureRect  # shows the frames
var playing := false
var paused := false

var _from := 0.0  # media time when the clock last (re)started
var _t0 := 0  # usec at that moment
var _paused_at := 0.0
var _run := false
var _ended := false
var _pids: Array[int] = []
var _threads: Array[Thread] = []
var _mutex := Mutex.new()
var _frame: Image
var _fresh := false
var _tex: ImageTexture
var _sound := AudioStreamPlayer.new()


func _ready() -> void:
	add_child(_sound)


func _exit_tree() -> void:
	stop()


## Current position in seconds.
func time() -> float:
	if not playing:
		return _from
	return _paused_at if paused else _from + (Time.get_ticks_usec() - _t0) / 1e6


## Starts playing `path` from `from` seconds, scaled to `size` (even numbers). False if ffmpeg won't start.
func play(ffmpeg: String, path: String, from: float, size: Vector2i) -> bool:
	stop()
	var base := ["-hide_banner", "-loglevel", "error", "-nostdin", "-ss", "%.3f" % from, "-i", path]
	var v := OS.execute_with_pipe(ffmpeg, base + ["-an", "-vf", "scale=%d:%d,fps=%d" % [size.x, size.y, FPS],
		"-pix_fmt", "rgba", "-f", "rawvideo", "pipe:1"])
	if v.is_empty():
		return false
	var a := OS.execute_with_pipe(ffmpeg, base + ["-vn", "-ac", "2", "-ar", "44100", "-f", "s16le", "pipe:1"])
	_pids = [v.pid]
	_from = from
	_t0 = Time.get_ticks_usec()
	playing = true
	paused = false
	_run = true
	_ended = false
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = 44100
	gen.buffer_length = 0.3
	_sound.stream = gen
	_sound.play()
	_start(_frames.bind(v.stdio, v.pid, size, from))
	if not a.is_empty():
		_pids.append(a.pid)
		_start(_audio.bind(a.stdio, a.pid, _sound.get_stream_playback()))
	return true


func set_paused(on: bool) -> void:
	if not playing or on == paused:
		return
	if on:
		_paused_at = time()
	else:
		_from = _paused_at
		_t0 = Time.get_ticks_usec()
	paused = on
	_sound.stream_paused = on


func stop() -> void:
	_run = false
	for pid in _pids:
		if OS.is_process_running(pid):
			OS.kill(pid)  # also unblocks the threads' pipe reads
	_pids.clear()
	for t in _threads:
		t.wait_to_finish()
	_threads.clear()
	_sound.stop()
	playing = false
	paused = false


func _start(work: Callable) -> void:
	var t := Thread.new()
	t.start(work)
	_threads.append(t)


func _process(_d: float) -> void:
	if _fresh:
		_mutex.lock()
		var img := _frame
		_fresh = false
		_mutex.unlock()
		if _tex and Vector2i(_tex.get_size()) == img.get_size():
			_tex.update(img)  # same size: reuse the texture, no reallocation
		else:
			_tex = ImageTexture.create_from_image(img)
		if target:
			target.texture = _tex
	if _ended and playing:
		stop()
		finished.emit()


## Reads exactly n bytes (pipes hand data over in pieces); fewer means the stream ended.
static func _read(pipe: FileAccess, pid: int, n: int) -> PackedByteArray:
	var out := PackedByteArray()
	while out.size() < n:
		var b := pipe.get_buffer(n - out.size())
		if b.is_empty():
			if not OS.is_process_running(pid):
				break
			OS.delay_msec(1)
			continue
		out.append_array(b)
	return out


## Worker: decodes frames and hands each one over when its time comes.
func _frames(pipe: FileAccess, pid: int, size: Vector2i, start: float) -> void:
	var bytes := size.x * size.y * 4
	var n := 0
	while _run:
		var buf := _read(pipe, pid, bytes)
		if buf.size() < bytes:
			break
		var due := start + n / float(FPS)
		n += 1
		while _run and (paused or time() < due):
			OS.delay_msec(2)
		if not _run:
			return
		if time() - due > 0.2:
			continue  # running late: skip this frame to catch up
		var img := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, buf)
		_mutex.lock()
		_frame = img
		_fresh = true
		_mutex.unlock()
	if _run:
		_ended = true


## Worker: feeds the sound to the generator as fast as it plays.
func _audio(pipe: FileAccess, pid: int, pb: AudioStreamGeneratorPlayback) -> void:
	while _run:
		var buf := _read(pipe, pid, 4096)
		if buf.is_empty():
			return
		var frames := PackedVector2Array()
		frames.resize(buf.size() / 4)
		for i in frames.size():
			frames[i] = Vector2(buf.decode_s16(i * 4), buf.decode_s16(i * 4 + 2)) / 32768.0
		while _run and pb.get_frames_available() < frames.size():
			OS.delay_msec(4)
		if _run:
			pb.push_buffer(frames)
