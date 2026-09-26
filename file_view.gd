extends Control
## FileView: a virtual list. Only the rows on screen are drawn, so a million files cost the same as ten.
## Views: TILES (thumbnail grid), COLUMNS (name grid), LIST, PATHS, DETAILS (sortable, resizable columns).
## Also: group header rows (click to fold), tick boxes, line numbers, drag / shift / ctrl selection.
## The host owns the data: it hands over `rows` and answers `cell(rec, key)`, `thumb(rec)`, `tip(rec)`.

signal activated(rec: int)  # double-click or Enter
signal context_requested(rec: int)  # right-click; -1 = empty space
signal selection_changed
signal cursor_changed(rec: int)
signal sort_requested(key: String)  # Details header click
signal group_toggled(g: int)  # group header click
signal columns_changed  # a column was resized

enum { TILES, COLUMNS, LIST, PATHS, DETAILS }
const THUMB := 64
const GRID_W := {TILES: 112, COLUMNS: 200}

var mode := LIST:
	set(v): mode = v; _relayout()
var checks := false:
	set(v): checks = v; queue_redraw()
var numbered := false:
	set(v): numbered = v; queue_redraw()
var columns: Array = []  # [{key, title, width}] shown in Details, in order
var sort_key := "name"
var sort_desc := false
var check_on: Texture2D
var check_off: Texture2D
var cell: Callable  # (rec, key) -> String
var thumb: Callable  # (rec) -> Texture2D or null
var tip: Callable  # (rec) -> String
var empty_text := ""  # shown in the middle when there are no rows

var rows := PackedInt32Array()  # >= 0 record index, < 0 group header -(g + 1)
var groups: Array = []  # [{title, count, collapsed}]
var sel := PackedByteArray()  # 1 = selected, one byte per record
var cursor := -1  # row index
var _anchor := -1
var _dragging := false
var _resizing := -1
var _per := 1  # items per line
# Only built when there are group headers; without them line maths is plain arithmetic.
var _lines := PackedInt32Array()  # first row of each line
var _line_y := PackedInt32Array()  # top of each line, then the total height
var _ord := PackedInt32Array()  # 1-based item number per row
var _vs := VScrollBar.new()
var _hs := HScrollBar.new()


func _ready() -> void:
	focus_mode = FOCUS_ALL
	clip_contents = true
	_vs.custom_minimum_size.x = 16  # Win95 scrollbars are 16 px
	_hs.custom_minimum_size.y = 16
	for sb: ScrollBar in [_vs, _hs]:
		sb.visible = false
		sb.value_changed.connect(func(_v: float) -> void: queue_redraw())
		add_child(sb)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_THEME_CHANGED:
		_relayout()


# --- public ------------------------------------------------------------------

func set_data(new_rows: PackedInt32Array, new_groups: Array, record_count: int, keep := false) -> void:
	rows = new_rows
	groups = new_groups
	if not keep or sel.size() != record_count:
		sel.resize(record_count)
		sel.fill(0)
		cursor = -1
		_anchor = -1
		_vs.value = 0
	cursor = mini(cursor, rows.size() - 1)
	_relayout()


## Selected records, in on-screen order.
func selected() -> PackedInt32Array:
	var out := PackedInt32Array()
	for r in rows:
		if r >= 0 and sel[r]:
			out.append(r)
	return out


func select_all() -> void:
	for r in rows:
		if r >= 0:
			sel[r] = 1
	_changed()


func clear_selection() -> void:
	sel.fill(0)
	_changed()


func set_selected(recs: PackedInt32Array) -> void:
	sel.fill(0)
	for r in recs:
		sel[r] = 1
	_changed()


func cursor_record() -> int:
	return rows[cursor] if cursor >= 0 and cursor < rows.size() and rows[cursor] >= 0 else -1


# --- metrics & layout --------------------------------------------------------

func _font() -> Font:
	return get_theme_font("font", "ItemList")


func _fs() -> int:
	return get_theme_font_size("font_size", "ItemList")


func _rh() -> int:
	return int(_font().get_height(_fs())) + 4


func _gh() -> int:  # group header line
	return _rh() + 6


func _hh() -> int:  # Details column header
	return _rh() + 4 if mode == DETAILS else 0


func _ih() -> int:  # one line of items
	return THUMB + 10 + 2 * int(_font().get_height(_fs())) if mode == TILES else _rh()


func _inner() -> Rect2:
	var p := get_theme_stylebox("panel", "ItemList")
	var r := Rect2(p.get_margin(SIDE_LEFT), p.get_margin(SIDE_TOP), 0, 0)
	r.end = size - Vector2(p.get_margin(SIDE_RIGHT), p.get_margin(SIDE_BOTTOM))
	if _vs.visible:
		r.size.x -= _vs.size.x
	if _hs.visible:
		r.size.y -= _hs.size.y
	return r


func _simple() -> bool:
	return groups.is_empty()


func _relayout() -> void:
	if not is_node_ready():
		return
	for pass_ in 2:  # the vertical scrollbar's width can change how many items fit per line
		var inner := _inner()
		_per = maxi(1, int(inner.size.x / GRID_W[mode])) if GRID_W.has(mode) else 1
		if not _simple():
			_build_lines()
		var view := inner.size.y - _hh()
		var need := _total_h() > view
		if need == _vs.visible:
			break
		_vs.visible = need
	var inner := _inner()
	var p := get_theme_stylebox("panel", "ItemList")
	_vs.position = Vector2(size.x - p.get_margin(SIDE_RIGHT) - _vs.size.x, inner.position.y)
	_vs.size.y = inner.size.y
	_vs.max_value = _total_h()
	_vs.page = inner.size.y - _hh()
	var tw := _columns_w()
	_hs.visible = mode == DETAILS and tw > inner.size.x
	inner = _inner()
	_hs.position = Vector2(inner.position.x, size.y - p.get_margin(SIDE_BOTTOM) - _hs.size.y)
	_hs.size.x = inner.size.x
	_hs.max_value = tw
	_hs.page = inner.size.x
	queue_redraw()


func _columns_w() -> float:
	var w := 0.0
	for c in columns:
		w += c.width
	return w


## Group headers break the item flow, so each line's start row and top edge get precomputed.
func _build_lines() -> void:
	_lines.clear()
	_line_y.clear()
	_ord.resize(rows.size())
	var y := 0
	var n := 0
	var i := 0
	var ih := _ih()
	while i < rows.size():
		_lines.append(i)
		_line_y.append(y)
		if rows[i] < 0:
			_ord[i] = 0
			i += 1
			y += _gh()
			continue
		var k := 0
		while k < _per and i < rows.size() and rows[i] >= 0:
			n += 1
			_ord[i] = n
			i += 1
			k += 1
		y += ih
	_line_y.append(y)


func _line_count() -> int:
	return ceili(rows.size() / float(_per)) if _simple() else _lines.size()


func _line_top(l: int) -> int:
	return l * _ih() if _simple() else _line_y[l]


func _line_h(l: int) -> int:
	return _ih() if _simple() or rows[_lines[l]] >= 0 else _gh()


func _line_start(l: int) -> int:
	return l * _per if _simple() else _lines[l]


func _line_end(l: int) -> int:
	if _simple():
		return mini((l + 1) * _per, rows.size())
	return _lines[l + 1] if l + 1 < _lines.size() else rows.size()


func _line_at(y: float) -> int:
	if _simple():
		return int(y / _ih())
	return clampi(_line_y.bsearch(int(y), false) - 1, 0, maxi(_lines.size() - 1, 0))


func _row_line(row: int) -> int:
	if _simple():
		return row / _per
	return _lines.bsearch(row, false) - 1


func _total_h() -> int:
	return _line_count() * _ih() if _simple() else (_line_y[-1] if _line_y.size() else 0)


func _ordinal(row: int) -> int:
	return row + 1 if _simple() else _ord[row]


## Row under a local position, or -1.
func _row_at(pos: Vector2) -> int:
	var inner := _inner()
	var y := pos.y - inner.position.y - _hh() + _vs.value
	if pos.y < inner.position.y + _hh() or y < 0 or y >= _total_h() or not inner.has_point(pos):
		return -1
	var l := _line_at(y)
	var s := _line_start(l)
	if rows[s] < 0:
		return s
	var i := s + int((pos.x - inner.position.x) / GRID_W[mode]) if GRID_W.has(mode) else s
	return i if i < _line_end(l) else -1


func _ensure_visible(row: int) -> void:
	var l := _row_line(row)
	var top := _line_top(l)
	var view := _inner().size.y - _hh()
	if top < _vs.value:
		_vs.value = top
	elif top + _line_h(l) > _vs.value + view:
		_vs.value = top + _line_h(l) - view


# --- drawing -----------------------------------------------------------------

func _draw() -> void:
	draw_style_box(get_theme_stylebox("panel", "ItemList"), Rect2(Vector2.ZERO, size))
	var inner := _inner()
	if rows.is_empty():
		if mode == DETAILS:
			_draw_header(inner)
		if empty_text != "":
			var p := TextParagraph.new()
			p.add_string(empty_text, _font(), _fs())
			p.width = inner.size.x - 40
			p.alignment = HORIZONTAL_ALIGNMENT_CENTER
			p.draw(get_canvas_item(), Vector2(inner.position.x + 20, inner.position.y + inner.size.y / 3),
				Color(get_theme_color("font_color", "ItemList"), 0.6))
		return
	var top := inner.position.y + _hh()
	for l in range(_line_at(_vs.value), _line_count()):
		var y := top + _line_top(l) - _vs.value
		if y > inner.end.y:
			break
		var s := _line_start(l)
		if rows[s] < 0:
			_draw_group(-rows[s] - 1, Rect2(inner.position.x, y, inner.size.x, _gh()))
			continue
		for i in range(s, _line_end(l)):
			var w: float = GRID_W.get(mode, maxf(inner.size.x, _columns_w() if mode == DETAILS else 0.0))
			var x := inner.position.x + (i - s) * w - (_hs.value if mode == DETAILS else 0.0)
			_draw_item(i, Rect2(x, y, w, _ih()))
	if mode == DETAILS:
		_draw_header(inner)


func _text(s: String, pos: Vector2, w: float, color: Color, align := HORIZONTAL_ALIGNMENT_LEFT, lines := 1) -> void:
	if w <= 4:
		return
	if lines > 1:
		var p := TextParagraph.new()
		p.add_string(s, _font(), _fs())
		p.width = w
		p.alignment = align
		p.max_lines_visible = lines
		p.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		p.break_flags = TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_GRAPHEME_BOUND
		p.draw(get_canvas_item(), pos, color)
		return
	var t := TextLine.new()
	t.add_string(s, _font(), _fs())
	t.width = w
	t.alignment = align
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	t.draw(get_canvas_item(), pos + Vector2(0, (_rh() - t.get_size().y) / 2), color)


func _draw_item(i: int, r: Rect2) -> void:
	var rec := rows[i]
	var on := sel[rec] == 1
	var ink := get_theme_color("font_selected_color" if on else "font_color", "ItemList")
	if on:
		draw_style_box(get_theme_stylebox("selected", "ItemList"), r.grow(-1) if GRID_W.has(mode) else r)
	if i == cursor and has_focus():
		draw_rect(r.grow(-1), Color(ink, 0.6), false)
	var x := r.position.x + 3
	var y := r.position.y
	var lead := ""
	if numbered:
		lead = "%d.  " % _ordinal(i)
	if mode == TILES:
		var box := Rect2(r.position.x + (r.size.x - THUMB) / 2, y + 4, THUMB, THUMB)
		var tex: Texture2D = thumb.call(rec) if thumb.is_valid() else null
		if tex:
			var sz := tex.get_size()
			var fit := sz * minf(THUMB / sz.x, THUMB / sz.y)
			draw_texture_rect(tex, Rect2(box.position + (box.size - fit) / 2, fit), false)
		else:  # no preview: show the type, big and quiet
			_text(cell.call(rec, "type").to_upper(), box.position + Vector2(0, THUMB / 2 - _rh() / 2), THUMB,
				Color(get_theme_color("font_color", "ItemList"), 0.35), HORIZONTAL_ALIGNMENT_CENTER)
		if checks:
			draw_texture(check_on if on else check_off, Vector2(r.position.x + 4, y + 4))
		_text(lead + cell.call(rec, "name"), Vector2(r.position.x + 3, y + THUMB + 7), r.size.x - 6, ink,
			HORIZONTAL_ALIGNMENT_CENTER, 2)
		return
	if checks:
		draw_texture(check_on if on else check_off, Vector2(x, y + (_rh() - check_on.get_height()) / 2))
		x += check_on.get_width() + 4
	if mode != DETAILS:
		_text(lead + cell.call(rec, "path" if mode == PATHS else "name"), Vector2(x, y), r.end.x - x - 3, ink)
		return
	var cx := r.position.x
	for c in columns:
		var start := x if cx == r.position.x else cx + 4
		var t: String = cell.call(rec, c.key)
		var right: bool = c.key in ["size", "length", "bitrate", "track"]
		_text((lead + t) if cx == r.position.x else t, Vector2(start, y), cx + c.width - start - 5, ink,
			HORIZONTAL_ALIGNMENT_RIGHT if right else HORIZONTAL_ALIGNMENT_LEFT)
		cx += c.width


func _draw_group(g: int, r: Rect2) -> void:
	var grp: Dictionary = groups[g]
	var ink := get_theme_color("font_color", "ItemList")
	_text("%s  %s  (%d)" % ["+" if grp.collapsed else "-", grp.title, grp.count],
		r.position + Vector2(4, 2), r.size.x - 8, ink)
	draw_line(Vector2(r.position.x + 2, r.end.y - 2), Vector2(r.end.x - 2, r.end.y - 2), Color(ink, 0.3))


func _draw_header(inner: Rect2) -> void:
	var box := get_theme_stylebox("normal", "Button")
	var ink := get_theme_color("font_color", "Button")
	var x := inner.position.x - _hs.value
	draw_style_box(box, Rect2(inner.position, Vector2(inner.size.x, _hh())))  # the strip past the last column
	for c in columns:
		var r := Rect2(x, inner.position.y, c.width, _hh())
		draw_style_box(box, r)
		var mark := ("  v" if sort_desc else "  ^") if c.key == sort_key else ""
		_text(c.title + mark, r.position + Vector2(5, 2), c.width - 10, ink)
		x += c.width


## Details header hit test: [column index, on its right edge?] or [-1, false].
func _header_hit(pos: Vector2) -> Array:
	var inner := _inner()
	if mode != DETAILS or pos.y < inner.position.y or pos.y >= inner.position.y + _hh():
		return [-1, false]
	var x := inner.position.x - _hs.value
	for c in columns.size():
		x += columns[c].width
		if absf(pos.x - x) <= 4:
			return [c, true]
		if pos.x < x:
			return [c, false]
	return [-1, false]


func _get_tooltip(at: Vector2) -> String:
	var i := _row_at(at)
	return tip.call(rows[i]) if i >= 0 and rows[i] >= 0 and tip.is_valid() else ""


# --- input -------------------------------------------------------------------

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		_mouse_button(e)
	elif e is InputEventMouseMotion:
		_mouse_motion(e)
	elif e is InputEventKey and e.pressed:
		_key(e)


func _mouse_button(e: InputEventMouseButton) -> void:
	if e.is_command_or_control_pressed() and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		return  # Ctrl+wheel is zoom; the host handles it
	match e.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			var d := (-1 if e.button_index == MOUSE_BUTTON_WHEEL_UP else 1) * _rh() * 3
			if e.shift_pressed and _hs.visible:
				_hs.value += d
			else:
				_vs.value += d
			accept_event()
		MOUSE_BUTTON_LEFT:
			if not e.pressed:
				_dragging = false
				_resizing = -1
				return
			grab_focus()
			var h := _header_hit(e.position)
			if h[0] >= 0:
				if h[1]:
					_resizing = h[0]
				else:
					sort_requested.emit(columns[h[0]].key)
				return
			var i := _row_at(e.position)
			if i >= 0 and rows[i] < 0:
				group_toggled.emit(-rows[i] - 1)
				return
			if e.double_click and i >= 0:
				activated.emit(rows[i])
				return
			_click(i, e.is_command_or_control_pressed() or checks, e.shift_pressed)
			_dragging = i >= 0 and not (checks or e.shift_pressed or e.is_command_or_control_pressed())
		MOUSE_BUTTON_RIGHT:
			if not e.pressed:
				return
			grab_focus()
			var i := _row_at(e.position)
			if i < 0 or rows[i] < 0:
				context_requested.emit(-1)
				return
			if not sel[rows[i]]:  # right-click outside the selection: that row becomes the selection
				_click(i, checks, false)
			context_requested.emit(rows[i])


func _mouse_motion(e: InputEventMouseMotion) -> void:
	if _resizing >= 0:
		columns[_resizing].width = maxf(30, columns[_resizing].width + e.relative.x)
		_relayout()
		columns_changed.emit()
		return
	var h := _header_hit(e.position)
	mouse_default_cursor_shape = CURSOR_HSIZE if h[1] else CURSOR_ARROW
	if not _dragging or not (e.button_mask & MOUSE_BUTTON_MASK_LEFT):
		return
	var inner := _inner()
	var p := e.position
	if p.y < inner.position.y + _hh() or p.y > inner.end.y:  # past an edge: scroll that way
		_vs.value += signf(p.y - inner.position.y - _hh()) * _rh()
	var i := _row_at(p.clamp(inner.position + Vector2(1, _hh() + 1), inner.end - Vector2(2, 2)))
	if i >= 0 and i != cursor:
		_click(i, false, true)


## Plain click: select just this row. toggle (Ctrl / tick mode): flip it. extend (Shift / drag): range from the anchor.
func _click(i: int, toggle: bool, extend: bool) -> void:
	if i < 0:
		if not toggle:
			sel.fill(0)
		_changed()
		return
	if extend and _anchor >= 0:
		if not toggle:
			sel.fill(0)
		for j in range(mini(_anchor, i), maxi(_anchor, i) + 1):
			if rows[j] >= 0:
				sel[rows[j]] = 1
	elif toggle:
		sel[rows[i]] ^= 1
		_anchor = i
	else:
		sel.fill(0)
		sel[rows[i]] = 1
		_anchor = i
	cursor = i
	cursor_changed.emit(rows[i])
	_changed()


func _changed() -> void:
	selection_changed.emit()
	queue_redraw()


func _key(e: InputEventKey) -> void:
	if rows.is_empty():
		return
	var page := maxi(1, int((_inner().size.y - _hh()) / _ih())) * _per
	var step := 0
	match e.keycode:
		KEY_UP: step = -_per
		KEY_DOWN: step = _per
		KEY_LEFT: step = -1 if _per > 1 else 0
		KEY_RIGHT: step = 1 if _per > 1 else 0
		KEY_PAGEUP: step = -page
		KEY_PAGEDOWN: step = page
		KEY_HOME: step = -rows.size()
		KEY_END: step = rows.size()
		KEY_ENTER, KEY_KP_ENTER:
			if cursor_record() >= 0:
				activated.emit(cursor_record())
			accept_event()
			return
		_:
			return
	accept_event()
	if step == 0:
		return
	var i := clampi((cursor if cursor >= 0 else -1) + step, 0, rows.size() - 1)
	var dir := signi(step)
	while rows[i] < 0 and i + dir >= 0 and i + dir < rows.size():  # hop over group headers
		i += dir
	if rows[i] < 0:
		return
	if e.is_command_or_control_pressed():  # move without selecting
		cursor = i
		cursor_changed.emit(rows[i])
		queue_redraw()
	else:
		_click(i, false, e.shift_pressed)
	_ensure_visible(i)
