extends Control
## Tune-O-Viewer: point it at folders, get one flat, searchable, sortable list of every matching file,
## with music tags, previews, playlists/CSV export, duplicate finding and Win95 looks.

const Tags = preload("res://tags.gd")
const FileView = preload("res://file_view.gd")
const VideoPlayer = preload("res://video_player.gd")

# Preset menu contents. Any other extension can be typed in.
const PRESETS := {
	"Audio": ["mp3", "flac", "wav", "ogg", "opus", "dsp"],
	"Video": ["mp4", "mkv", "webm", "mov", "avi"],
	"Code": ["gd", "py", "cpp", "h", "json"],
	"Images": ["png", "jpg", "webp", "svg"],
	"Documents": ["txt", "md", "pdf"],
}
const IMAGE_EXT := ["png", "jpg", "jpeg", "webp", "svg", "bmp", "tga"]
const PLAYABLE := ["mp3", "ogg", "wav"]  # what Godot can decode; FLAC/Opus/DSP get info only
const VIDEO_EXT := ["mp4", "m4v", "mkv", "webm", "mov", "avi", "wmv", "flv", "mpg", "mpeg", "ogv", "3gp", "ts"]
const VIDEO_MAX := Vector2i(640, 360)  # preview frame size cap: plenty for the pane, cheap to decode
const DEFAULT_SKIPS := [".git", "node_modules", "$RECYCLE.BIN", "System Volume Information"]
const FOLDER_ART := ["cover.jpg", "folder.jpg", "front.jpg", "cover.png", "folder.png", "AlbumArtSmall.jpg"]
const BATCH := 1000  # files per hand-off from worker threads
const LIVE_LIMIT := 100000  # past this, the list isn't re-sorted while a scan streams in
const PREFS := "user://settings.cfg"
const INDEX := "user://index.bin"
const THUMBS := "user://thumbs"
const ZOOMS := [1.0, 1.5, 2.0, 2.5, 3.0, 4.0]
const VIEWS := ["Tiles", "Columns", "List", "Paths", "Details"]  # same order as FileView's modes
const SORTS := {"name": "Name", "type": "Type", "size": "Size", "modified": "Modified", "folder": "Folder",
	"artist": "Artist", "album": "Album", "title": "Title", "track": "Track", "year": "Year", "length": "Length"}
const GROUPS := {"none": "None", "folder": "Folder", "type": "Type", "artist": "Artist", "album": "Album", "year": "Year"}
# Details columns: key -> [title, default width]. DEFAULT_COLUMNS are shown on first run.
const COLUMN_DEFS := {"name": ["Name", 220], "type": ["Type", 45], "size": ["Size", 70], "modified": ["Modified", 115],
	"length": ["Length", 50], "artist": ["Artist", 130], "album": ["Album", 130], "title": ["Title", 150],
	"track": ["Track", 40], "year": ["Year", 45], "bitrate": ["kbps", 45], "folder": ["Folder", 260]}
const DEFAULT_COLUMNS := ["name", "type", "size", "modified", "length", "artist", "album", "folder"]

# Key (as InputEventKey.as_text_keycode() spells it) -> [what it does, method, args...].
# Drives the key handling, the Help > Keyboard Shortcuts dialog and the menus' key hints.
# An empty method = handled natively, listed for the help only.
const SHORTCUTS := {
	"F5": ["Scan", "_start_scan"],
	"Escape": ["Stop scan / leave duplicates / clear search", "_escape"],
	"Ctrl+O": ["Browse for a folder to add", "_browse"],
	"Ctrl+L": ["Type a folder path to add", "_focus", "%PathEdit"],
	"Ctrl+F": ["Search", "_focus", "%SearchEdit"],
	"Ctrl+T": ["Type a file type to add", "_focus", "%CustomEdit"],
	"Ctrl+A": ["Select all", "_select_all"],
	"Ctrl+C": ["Copy selected names", "_copy_selected", false],
	"Ctrl+Shift+C": ["Copy selected paths", "_copy_selected", true],
	"Enter": ["Open file (or double-click)", ""],
	"Space": ["Play / pause in the preview", "_toggle_play"],
	"Ctrl+E": ["Show file in its folder", "_reveal"],
	"Delete": ["Send selected to the Recycle Bin", "_recycle"],
	"F2": ["Rename selected files, one after another", "_rename_start"],
	"Ctrl+S": ["Export playlist (M3U)", "_export", "m3u"],
	"Ctrl+Shift+S": ["Export list (CSV)", "_export", "csv"],
	"Ctrl+Shift+D": ["Find duplicate files", "_find_dupes"],
	"Ctrl+1": ["Tiles view", "_set_view", 0],
	"Ctrl+2": ["Columns view", "_set_view", 1],
	"Ctrl+3": ["List view", "_set_view", 2],
	"Ctrl+4": ["Paths view", "_set_view", 3],
	"Ctrl+5": ["Details view", "_set_view", 4],
	"Alt+P": ["Preview pane on/off", "_set_preview", null],
	"Ctrl+D": ["Dark mode on/off", "_set_dark", null],
	"Ctrl+K": ["Checkbox select mode on/off", "_set_checks", null],
	"Ctrl+N": ["Line numbers on/off", "_set_numbered", null],
	"Ctrl+M": ["Sounds on/off", "_set_sounds", null],
	"Ctrl+Equal": ["Zoom in (or Ctrl+wheel)", "_zoom", 1],
	"Ctrl+Minus": ["Zoom out", "_zoom", -1],
	"Ctrl+0": ["Reset zoom", "_zoom", 0],
	"F11": ["Fullscreen on/off (or double-click title)", "_toggle_fullscreen"],
	"F1": ["Keyboard shortcuts", "_show_help"],
	"Alt+F4": ["Close", ""],
	"Drag": ["Select a run of files (mouse)", ""],
	"Drop": ["Drop folders (or files) from Explorer to add them", ""],
}

# Colour roles. hi/lite = lit bevel edges, shade/deep = shadowed edges, face = gray chrome,
# field = list/text-box background, ink = text, dim = disabled text, sel = highlight.
const LIGHT_PAL := {
	hi = Color("ffffff"), lite = Color("dfdfdf"), face = Color("c0c0c0"), shade = Color("808080"),
	deep = Color("000000"), field = Color("ffffff"), ink = Color("000000"), dim = Color("808080"),
	sel = Color("000080"), sel_ink = Color("ffffff"),
}
const DARK_PAL := {
	hi = Color("707070"), lite = Color("4a4a4a"), face = Color("2e2e2e"), shade = Color("1a1a1a"),
	deep = Color("000000"), field = Color("1c1c1c"), ink = Color("e6e6e6"), dim = Color("7a7a7a"),
	sel = Color("2a4a9a"), sel_ink = Color("ffffff"),
}
var P := LIGHT_PAL

const GRIP := 5  # px from the window edge that start a resize
# (dx, dy) of the edge under the mouse -> [resize edge, cursor]
const EDGES := {
	Vector2i(-1, -1): [DisplayServer.WINDOW_EDGE_TOP_LEFT, CURSOR_FDIAGSIZE],
	Vector2i(0, -1): [DisplayServer.WINDOW_EDGE_TOP, CURSOR_VSIZE],
	Vector2i(1, -1): [DisplayServer.WINDOW_EDGE_TOP_RIGHT, CURSOR_BDIAGSIZE],
	Vector2i(-1, 0): [DisplayServer.WINDOW_EDGE_LEFT, CURSOR_HSIZE],
	Vector2i(1, 0): [DisplayServer.WINDOW_EDGE_RIGHT, CURSOR_HSIZE],
	Vector2i(-1, 1): [DisplayServer.WINDOW_EDGE_BOTTOM_LEFT, CURSOR_BDIAGSIZE],
	Vector2i(0, 1): [DisplayServer.WINDOW_EDGE_BOTTOM, CURSOR_VSIZE],
	Vector2i(1, 1): [DisplayServer.WINDOW_EDGE_BOTTOM_RIGHT, CURSOR_FDIAGSIZE],
}

@onready var fv: FileView = %FileView
@onready var search: LineEdit = %SearchEdit
@onready var path_edit: LineEdit = %PathEdit
@onready var folders: HFlowContainer = %Folders
@onready var presets: PopupMenu = (%Presets as MenuButton).get_popup()
@onready var custom_edit: LineEdit = %CustomEdit
@onready var tags: HFlowContainer = %Tags
@onready var skips_box: HFlowContainer = %Skips
@onready var scan_button: Button = %ScanButton
@onready var status: Label = %Status
@onready var dialog: FileDialog = %FolderDialog
@onready var save_dialog: FileDialog = %SaveDialog
@onready var menu: PopupMenu = %ContextMenu
@onready var help: AcceptDialog = %HelpDialog
@onready var about: AcceptDialog = %AboutDialog
@onready var confirm: ConfirmationDialog = %ConfirmDialog
@onready var player: AudioStreamPlayer = %Player

# One entry per found file, stored column-wise: packed arrays stay compact even at a million files.
var _path := PackedStringArray()
var _size := PackedInt64Array()  # -1 until the details pass has read it
var _mtime := PackedInt64Array()
var _title := PackedStringArray()
var _artist := PackedStringArray()
var _album := PackedStringArray()
var _year := PackedStringArray()
var _track := PackedStringArray()
var _length := PackedFloat32Array()  # seconds, 0 = unknown
var _kbps := PackedInt32Array()
const FIELDS := ["_path", "_size", "_mtime", "_title", "_artist", "_album", "_year", "_track", "_length", "_kbps"]

var _roots: Array[String] = []  # folders to scan, "/"-separated
var _exts: Array[String] = []  # active type filter, lowercase, no dots; empty = all files
var _skips: Array[String] = []  # folder names (or * patterns) never entered
var _view := 2
var _sort := "name"
var _desc := false
var _group := "none"
var _collapsed := {}  # group title -> true
var _numbered := false
var _check_on: ImageTexture
var _check_off: ImageTexture

var _thread := Thread.new()  # scan + details pass
var _abort := false
var _gen := 0  # bumps every scan; late results from an older scan are ignored
var _phase := ""  # "", "scan", "details"
var _dirs := 0
var _details_done := 0
var _live_dirty := false
var _index_dirty := false

var _job := Thread.new()  # duplicates / copy / move
var _job_abort := false
var _dupe_sets: Array = []  # Array[PackedStringArray] of identical files; non-empty = duplicates view
var _dupe_of := {}  # path -> set index

var _thumbs := {}  # path -> Texture2D, or null while pending / when there is none
var _thumb_tasks: Array[int] = []
var _preview_rec := -1
var _seeking := false
var _menu_rec := -1
var _save_kind := ""
var _dialog_purpose := "add"  # FolderDialog: "add" a scan folder, or "copy"/"move" the selection
var _pending_recs := PackedInt32Array()
var _confirm_action: Callable
var _rename := ConfirmationDialog.new()
var _rename_edit := LineEdit.new()
var _rename_note := Label.new()
var _rename_queue := PackedInt32Array()  # records still to rename, in list order
var _rename_total := 0
var _renamed := 0
var _menus: Array = []  # [PopupMenu, spec] for check-mark syncing
var _shown_n := 0
var _sounds := true
var _font_path := ""  # user's own font, copied into FONTS; "" = the built-in Win95 font
var _font_dialog := FileDialog.new()
const FONTS := "user://fonts"
const LINKS := [["github.com/Tune-0-Matic/tune-o-viewer", "https://github.com/Tune-0-Matic/tune-o-viewer"],
	["zfactorpsx.itch.io/tune-o-viewer", "https://zfactorpsx.itch.io/tune-o-viewer"]]
const IMAGE_OUT := ["png", "jpg", "webp"]  # Godot writes these itself
const AUDIO_OUT := ["mp3", "wav", "ogg", "flac", "opus"]  # these go through ffmpeg
# ffmpeg arguments per output format (-vn drops cover art where the format can't carry it simply)
const FFMPEG_ARGS := {"mp3": ["-codec:a", "libmp3lame", "-q:a", "2"], "wav": ["-vn", "-codec:a", "pcm_s16le"],
	"ogg": ["-vn", "-codec:a", "libvorbis", "-q:a", "5"], "flac": ["-vn", "-codec:a", "flac"],
	"opus": ["-vn", "-codec:a", "libopus", "-b:a", "128k"]}
var _welcome := AcceptDialog.new()
var _video := VideoPlayer.new()
var _video_size := Vector2i.ZERO  # frame size for the previewed video; zero = not a playable video
var _ffmpeg := ""  # found on first use; "-" = looked, not installed
const FONT_EXT := ["ttf", "otf", "ttc", "woff", "woff2", "fnt", "fon"]
var _sfx := AudioStreamPlayer.new()  # UI blips; the preview has its own player
var _sfx_cache := {}
const CLICK := [[880.0, 0.03]]
const DONE := [[660.0, 0.08], [880.0, 0.14]]
# The opening tune: E5 G5 D6, landing on a long, ringing C6 (a little "ta-da").
const JINGLE := [[659.25, 0.12, true], [783.99, 0.12, true], [1174.66, 0.14, true], [1046.5, 0.7, true]]
var _rescan := Timer.new()  # short delay so several quick changes cause one rescan
var _rescan_pending := false  # a change came in mid-scan: scan again when it ends
var _shown_bytes := 0


func _ready() -> void:
	_fit_min_size.call_deferred()  # after the first layout pass
	var name_ver := "Tune-O-Viewer  v" + str(ProjectSettings.get_setting("application/config/version", "1.0"))
	%Title.text = name_ver
	get_window().title = name_ver  # the taskbar shows it too
	DirAccess.make_dir_recursive_absolute(THUMBS)
	fv.cell = _cell
	fv.thumb = _thumb
	fv.tip = func(rec: int) -> String: return _path[rec]
	fv.activated.connect(func(rec: int) -> void: OS.shell_open(_path[rec]))
	fv.context_requested.connect(_popup_menu)
	fv.cursor_changed.connect(_preview)
	fv.selection_changed.connect(_update_status)
	fv.sort_requested.connect(func(key: String) -> void: _set_sort(key, not _desc if key == _sort else false))
	fv.group_toggled.connect(_toggle_group)
	_build_menus()
	for cat in PRESETS:
		presets.add_separator(cat)
		for ext in PRESETS[cat]:
			presets.add_check_item(ext)
	presets.hide_on_checkable_item_selection = false  # tick several without reopening
	presets.index_pressed.connect(func(i: int) -> void: _toggle(presets.get_item_text(i)))
	%AddButton.pressed.connect(_add_custom)
	custom_edit.text_submitted.connect(func(_t: String) -> void: _add_custom())
	%ClearButton.pressed.connect(func() -> void:
		_set_exts([])
		_filters_changed())
	_rescan.one_shot = true
	_rescan.wait_time = 0.5
	_rescan.timeout.connect(_auto_scan)
	add_child(_rescan)
	%SkipAddButton.pressed.connect(_add_skip)
	%SkipEdit.text_submitted.connect(func(_t: String) -> void: _add_skip())
	# Native pickers where the display server has them; else the built-in (themed) dialogs.
	var native := DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE)
	dialog.use_native_dialog = native
	save_dialog.use_native_dialog = native
	%BrowseButton.pressed.connect(_browse)
	dialog.dir_selected.connect(_on_dir_chosen)
	save_dialog.file_selected.connect(_write_export)
	%AddFolderButton.pressed.connect(_add_typed_folder)
	path_edit.text_submitted.connect(func(_t: String) -> void: _add_typed_folder())
	get_window().files_dropped.connect(_on_dropped)
	scan_button.pressed.connect(func() -> void: _escape() if _phase != "" else _start_scan())
	search.text_changed.connect(func(_t: String) -> void: %SearchTimer.start())
	%SearchTimer.timeout.connect(_rebuild)
	%SelectButton.toggled.connect(_set_checks)
	%NumberButton.toggled.connect(_set_numbered)
	%PreviewButton.toggled.connect(_set_preview)
	%PlayButton.pressed.connect(_toggle_play)
	%Seek.drag_started.connect(func() -> void: _seeking = true)
	%Seek.drag_ended.connect(func(_c: bool) -> void:
		_seeking = false
		if player.stream:
			player.seek(%Seek.value)
		elif _video_size != Vector2i.ZERO:
			_play_video(%Seek.value))
	_video.target = %PreviewImage
	_video.finished.connect(func() -> void:
		%PlayButton.text = "Play"
		%Seek.value = 0)
	add_child(_video)
	%CopyToButton.pressed.connect(_collect.bind(false))
	%MoveToButton.pressed.connect(_collect.bind(true))
	confirm.confirmed.connect(func() -> void: _confirm_action.call())
	%CloseButton.pressed.connect(get_tree().quit)
	%TitleBar.gui_input.connect(_on_title_input)
	%MaxButton.pressed.connect(_toggle_fullscreen)
	%Grip.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and e.pressed:
			DisplayServer.window_start_resize(DisplayServer.WINDOW_EDGE_BOTTOM_RIGHT))
	menu.popup_hide.connect(func() -> void: set.call_deferred("_menu_rec", -1))
	_build_help()
	_build_about()
	_build_welcome()
	_build_rename()
	add_child(_sfx)
	_font_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_font_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_font_dialog.title = "Choose a Font"
	_font_dialog.filters = PackedStringArray(["*.ttf, *.otf, *.ttc, *.woff, *.woff2, *.fnt, *.fon ; Fonts"])
	_font_dialog.use_native_dialog = DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE)
	_font_dialog.current_dir = "C:/Windows/Fonts" if OS.get_name() == "Windows" else ""
	_font_dialog.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	_font_dialog.file_selected.connect(_use_font)
	add_child(_font_dialog)
	_hook_clicks(self)
	_load_prefs()
	for w: Window in [dialog, save_dialog, menu, presets, help, about, confirm]:
		w.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST  # subwindows skip the project default
	if _load_index():
		_start_scan.call_deferred(true)  # show last time's list now, refresh it quietly
	else:
		_rebuild(false)  # empty list: shows what to do next


func _process(_d: float) -> void:
	if player.playing and not _seeking:
		%Seek.value = player.get_playback_position()
	if _video.playing and not _seeking:
		%Seek.value = _video.time()
	if player.stream or _video_size != Vector2i.ZERO:
		%TimeLabel.text = "%s / %s" % [_dur(%Seek.value), _dur(%Seek.max_value)]
	for id in _thumb_tasks.duplicate():  # every pool task must be waited on exactly once
		if WorkerThreadPool.is_task_completed(id):
			WorkerThreadPool.wait_for_task_completion(id)
			_thumb_tasks.erase(id)


# --- window chrome -----------------------------------------------------------

func _on_title_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and e.pressed:
		if e.double_click:
			_toggle_fullscreen()
		elif not _fullscreen():
			DisplayServer.window_start_drag()


func _fullscreen() -> bool:
	return get_window().mode == Window.MODE_FULLSCREEN


## Fullscreen also scales the whole UI (text, bevels, icons) to suit the screen:
## 2x on 1080p/1440p, 4x on 4K; whole numbers keep the pixel edges crisp.
func _toggle_fullscreen() -> void:
	var w := get_window()
	var full := not _fullscreen()
	w.mode = Window.MODE_FULLSCREEN if full else Window.MODE_WINDOWED
	w.content_scale_factor = _base_scale()
	%MaxButton.icon = _frame_icon(not full)
	%Grip.visible = not full


func _base_scale() -> float:
	if not _fullscreen():
		return 1.0
	return maxf(1.5, floorf(DisplayServer.screen_get_size(get_window().current_screen).y / 540.0))


## dir +1/-1 steps through ZOOMS; 0 goes back to the default for the window mode.
func _zoom(dir: int) -> void:
	var w := get_window()
	var z := w.content_scale_factor
	var m := ($Window as Control).get_combined_minimum_size()
	var fit := minf(w.size.x / m.x, w.size.y / m.y)  # don't zoom past what the window can lay out
	var next := ZOOMS.filter(func(s: float) -> bool: return (s > z and s <= fit) if dir > 0 else s < z)
	if dir == 0:
		z = _base_scale()
	elif not next.is_empty():
		z = next.front() if dir > 0 else next.back()
	w.content_scale_factor = z
	_fit_min_size()
	status.text = "Zoom %d%%" % roundi(z * 100)


## The window can't be dragged smaller than the layout needs at the current zoom.
func _fit_min_size() -> void:
	var w := get_window()
	var keep := w.size  # Godot 4.7 snaps the window to min_size when it's set; don't let it shrink
	w.min_size = Vector2i((($Window as Control).get_combined_minimum_size() * w.content_scale_factor).ceil())
	w.size = keep.max(w.min_size)


## Borderless resize (the OS does it once told which edge was grabbed), and Ctrl+wheel zoom.
func _input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.is_command_or_control_pressed() \
			and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		_zoom(1 if e.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
		get_viewport().set_input_as_handled()
		return
	if not e is InputEventMouse or _fullscreen():
		return
	var p: Vector2 = e.position
	var key := Vector2i(-int(p.x < GRIP) + int(p.x > size.x - GRIP), -int(p.y < GRIP) + int(p.y > size.y - GRIP))
	var hit = EDGES.get(key)
	Input.set_default_cursor_shape(hit[1] if hit else CURSOR_ARROW)
	if hit and e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and e.pressed:
		DisplayServer.window_start_resize(hit[0])
		get_viewport().set_input_as_handled()


func _shortcut_input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	var s = SHORTCUTS.get((e as InputEventKey).as_text_keycode())
	if s and s[1] != "":
		callv(s[1], s.slice(2))
		get_viewport().set_input_as_handled()


# --- menus, help, about ------------------------------------------------------

func _build_menus() -> void:
	var sort_menu := _menu_from([["Descending", "_set_desc", null], "-"]
		+ SORTS.keys().map(func(k: String) -> Array: return [SORTS[k], "_set_sort", k]))
	var group_menu := _menu_from(GROUPS.keys().map(func(k: String) -> Array: return [GROUPS[k], "_set_group", k]))
	var col_menu := _menu_from(COLUMN_DEFS.keys().filter(func(k: String) -> bool: return k != "name")
		.map(func(k: String) -> Array: return [COLUMN_DEFS[k][0], "_toggle_column", k]))
	_fill_menu((%FileMenu as MenuButton).get_popup(), [
		["Add Folder...", "_browse"], ["Scan", "_start_scan"], "-",
		["Convert Selected To", _convert_menu()], "-",
		["Export Playlist (M3U)...", "_export", "m3u"], ["Export List (CSV)...", "_export", "csv"], "-",
		["Copy Selected To Folder...", "_collect", false], ["Move Selected To Folder...", "_collect", true],
		["Rename Selected...", "_rename_start"], ["Send Selected to Recycle Bin", "_recycle"], "-", ["Exit", "_quit"]])
	_fill_menu((%EditMenu as MenuButton).get_popup(), [
		["Select All", "_select_all"], ["Select None", "_select_none"], ["Checkbox Mode", "_set_checks", null], "-",
		["Copy Names", "_copy_selected", false], ["Copy Paths", "_copy_selected", true], ["Copy Whole List", "_copy_list"], "-",
		["Search", "_focus", "%SearchEdit"], ["Find Duplicates", "_find_dupes"],
		["Select Extra Copies", "_select_extra_copies"], ["Show All Files", "_leave_dupes"]])
	var view_spec: Array = VIEWS.map(func(v: String) -> Array: return [v, "_set_view", VIEWS.find(v)])
	_fill_menu((%ViewMenu as MenuButton).get_popup(), view_spec + ["-",
		["Sort By", sort_menu], ["Group By", group_menu], ["Details Columns", col_menu], "-",
		["Preview Pane", "_set_preview", null], ["Line Numbers", "_set_numbered", null], ["Dark Mode", "_set_dark", null], ["Sounds", "_set_sounds", null], "-",
		["Font...", "_pick_font"], ["Default Font", "_reset_font"], "-",
		["Zoom In", "_zoom", 1], ["Zoom Out", "_zoom", -1], ["Reset Zoom", "_zoom", 0], ["Fullscreen", "_toggle_fullscreen"]])
	_fill_menu((%HelpMenu as MenuButton).get_popup(), [
		["Keyboard Shortcuts...", "_show_help"], ["About Tune-O-Viewer...", "_show_about"]])
	for mb: MenuButton in [%FileMenu, %EditMenu, %ViewMenu, %HelpMenu]:
		mb.set_disable_shortcuts(true)  # key hints are labels only; SHORTCUTS does the dispatch (else keys fire twice)
		mb.get_popup().canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	_fill_menu(menu, [["Open", "_open_rec"], ["Show in Folder", "_reveal"], ["Play in Preview", "_play_rec"], "-",
		["Copy Names", "_copy_selected", false], ["Copy Paths", "_copy_selected", true], "-",
		["Copy To Folder...", "_collect", false], ["Move To Folder...", "_collect", true],
		["Rename...", "_rename_start"], ["Convert To", _convert_menu()], ["Send to Recycle Bin", "_recycle"], "-",
		["Select All", "_select_all"]])


func _convert_menu() -> PopupMenu:
	return _menu_from(IMAGE_OUT.map(func(f: String) -> Array: return [f.to_upper() + " picture", "_convert", f]) + ["-"]
		+ AUDIO_OUT.map(func(f: String) -> Array: return [f.to_upper() + " audio", "_convert", f]))


func _menu_from(spec: Array) -> PopupMenu:
	var pm := PopupMenu.new()
	pm.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	_fill_menu(pm, spec)
	return pm


## spec items: "-" separator, [label, PopupMenu] submenu, or [label, method, args...].
## Items whose method is a setting (see _is_on) get a check mark; key hints come from SHORTCUTS.
func _fill_menu(pm: PopupMenu, spec: Array) -> void:
	for i in spec.size():
		var it = spec[i]
		if it is String:
			pm.add_separator()
		elif it[1] is PopupMenu:
			pm.add_submenu_node_item(it[0], it[1], i)
		else:
			if _is_on(it[1], it.slice(2)) != null:
				pm.add_check_item(it[0], i)
			else:
				pm.add_item(it[0], i)
			var key := _key_for(it[1], it.slice(2))
			if key != "":
				var sc := Shortcut.new()
				sc.events = [_key_event(key)]
				pm.set_item_shortcut(pm.get_item_index(i), sc)
	pm.id_pressed.connect(func(id: int) -> void:
		_beep(CLICK)
		callv(spec[id][1], spec[id].slice(2)))
	_menus.append([pm, spec])


func _key_for(method: String, args: Array) -> String:
	for k in SHORTCUTS:
		if SHORTCUTS[k][1] == method and SHORTCUTS[k].slice(2) == args:
			return k
	return ""


func _key_event(text: String) -> InputEventKey:
	var e := InputEventKey.new()
	var parts := text.split("+")
	e.ctrl_pressed = "Ctrl" in parts
	e.shift_pressed = "Shift" in parts
	e.alt_pressed = "Alt" in parts
	e.keycode = OS.find_keycode_from_string(parts[-1])
	return e


## Check-mark state for a menu item, or null when the item isn't a setting.
func _is_on(method: String, args: Array) -> Variant:
	match method:
		"_set_view": return _view == args[0]
		"_set_sort": return _sort == args[0]
		"_set_desc": return _desc
		"_set_group": return _group == args[0]
		"_toggle_column": return fv.columns.any(func(c: Dictionary) -> bool: return c.key == args[0])
		"_set_preview": return %Preview.visible
		"_set_numbered": return _numbered
		"_set_dark": return P == DARK_PAL
		"_set_checks": return fv.checks
		"_set_sounds": return _sounds
	return null


func _sync_menus() -> void:
	for m in _menus:
		var pm: PopupMenu = m[0]
		for i in m[1].size():
			var it = m[1][i]
			if it is Array and it[1] is String:
				var on = _is_on(it[1], it.slice(2))
				if on != null:
					pm.set_item_checked(pm.get_item_index(i), on)


func _build_help() -> void:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 24)
	for key in SHORTCUTS:
		for text in [key, SHORTCUTS[key][0]]:
			var l := Label.new()
			l.text = text.replace("Equal", "=").replace("Minus", "-")
			grid.add_child(l)
	help.add_child(grid)


func _build_about() -> void:
	about.add_child(_card(["Tune-O-Viewer  v" + str(ProjectSettings.get_setting("application/config/version", "1.0")),
		"Every file in every folder, in one flat list.", "Settings and cache: " + OS.get_user_data_dir()]))


## Shown every time the app opens.
func _build_welcome() -> void:
	_welcome.title = "Welcome"
	_welcome.ok_button_text = "Enter"
	_welcome.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	_welcome.add_child(_card(["Welcome To Tune-O-Viewer!", "Please Consider Joining The Discord Or Donating To The Itch!",
		"Thank You!"]))
	add_child(_welcome)
	for d: AcceptDialog in [_welcome, about, help]:
		d.exclusive = false  # Godot ignores the window's close button while an exclusive dialog is open
	_welcome.popup_centered.call_deferred()
	_beep.call_deferred(JINGLE)  # after settings load, so Sounds off keeps it quiet


## The app icon, some centred lines, then the GitHub and itch.io links.
func _card(lines: Array) -> VBoxContainer:
	var box := VBoxContainer.new()
	var icon := TextureRect.new()
	icon.texture = load("res://icon.jpg")
	icon.custom_minimum_size = Vector2(96, 96)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	box.add_child(icon)
	for text in lines:
		var l := Label.new()
		l.text = text
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(l)
	for pair in LINKS:
		var link := LinkButton.new()
		link.text = pair[0]
		link.uri = pair[1]
		link.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		box.add_child(link)
	return box


func _show_help() -> void:
	help.popup_centered()


func _show_about() -> void:
	about.popup_centered()


func _quit() -> void:
	get_tree().quit()


# --- small actions -----------------------------------------------------------

func _browse() -> void:
	_dialog_purpose = "add"
	dialog.title = "Add a Folder"
	dialog.popup_centered_ratio(0.7)


func _focus(unique: String) -> void:
	var le: LineEdit = get_node(unique)
	le.grab_focus()
	le.select_all()


func _select_all() -> void:
	fv.select_all()


func _select_none() -> void:
	fv.clear_selection()


## Selected records, or the one under the cursor when nothing is selected.
func _targets() -> PackedInt32Array:
	var s := fv.selected()
	if s.is_empty() and fv.cursor_record() >= 0:
		s.append(fv.cursor_record())
	return s


func _copy_selected(paths: bool) -> void:
	_copy(_targets(), paths)


func _copy_list() -> void:
	_copy(_shown(), false)


func _shown() -> PackedInt32Array:
	var out := PackedInt32Array()
	for r in fv.rows:
		if r >= 0:
			out.append(r)
	return out


## Copies one name (or full path) per line. With line numbers on, names carry
## the same "12.  " the list shows.
func _copy(recs: PackedInt32Array, paths: bool) -> void:
	var num := {}  # record -> its on-screen number
	if _numbered and not paths:
		for r in fv.rows:
			if r >= 0:
				num[r] = num.size() + 1
	var out := PackedStringArray()
	for r in recs:
		var name := _path[r].get_file()
		out.append(_path[r] if paths else ("%d.  %s" % [num[r], name] if num.has(r) else name))
	DisplayServer.clipboard_set("\n".join(out))
	status.text = "Copied %d %s to the clipboard." % [out.size(), "paths" if paths else "names"]


func _menu_or_cursor() -> int:
	return _menu_rec if _menu_rec >= 0 and _menu_rec < _path.size() else fv.cursor_record()


func _open_rec() -> void:
	if _menu_or_cursor() >= 0:
		OS.shell_open(_path[_menu_or_cursor()])


func _reveal() -> void:
	if _menu_or_cursor() >= 0:
		OS.shell_show_in_file_manager(_path[_menu_or_cursor()])


func _play_rec() -> void:
	_set_preview(true)
	_preview(_menu_or_cursor())
	_toggle_play()


func _popup_menu(rec: int) -> void:
	_menu_rec = rec
	var has_sel := not _targets().is_empty()
	var spec: Array = _menus.filter(func(m: Array) -> bool: return m[0] == menu)[0][1]
	for id in spec.size():
		var it = spec[id]
		if it is String:
			continue
		var ok := has_sel  # most items act on the selection
		match it[1] if it[1] is String else "":
			"_open_rec", "_reveal": ok = rec >= 0
			"_play_rec": ok = rec >= 0 and _path[rec].get_extension().to_lower() in PLAYABLE + VIDEO_EXT
			"_select_all": ok = not fv.rows.is_empty()
		menu.set_item_disabled(menu.get_item_index(id), not ok)
	menu.popup(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO))


## Esc: stop a scan, else leave the duplicates view, else clear the search.
func _escape() -> void:
	if _phase != "":
		_abort = true
	elif _job.is_started():
		_job_abort = true
	elif not _dupe_sets.is_empty():
		_leave_dupes()
	elif search.text != "":
		search.clear()
		_rebuild()


# --- settings that change the view -------------------------------------------

func _set_view(v: int) -> void:
	_view = v
	fv.mode = v
	if v == FileView.DETAILS and fv.columns.is_empty():
		_set_columns(DEFAULT_COLUMNS.map(func(k: String) -> Array: return [k, COLUMN_DEFS[k][1]]))
	_sync_menus()


func _set_columns(cols: Array) -> void:
	fv.columns = cols.filter(func(c: Array) -> bool: return COLUMN_DEFS.has(c[0])).map(
		func(c: Array) -> Dictionary: return {key = c[0], title = COLUMN_DEFS[c[0]][0], width = float(c[1])})
	fv.sort_key = _sort
	fv.sort_desc = _desc
	fv._relayout()


func _toggle_column(key: String) -> void:
	var cols: Array = fv.columns.map(func(c: Dictionary) -> Array: return [c.key, c.width])
	var at := cols.map(func(c: Array) -> String: return c[0]).find(key)
	if at >= 0:
		cols.remove_at(at)
	else:
		cols.append([key, COLUMN_DEFS[key][1]])
	_set_columns(cols)
	_sync_menus()


func _set_sort(key: String, desc = null) -> void:
	_sort = key
	if desc != null:
		_desc = desc
	fv.sort_key = _sort
	fv.sort_desc = _desc
	_rebuild(true)
	_sync_menus()


func _set_desc(on = null) -> void:
	_set_sort(_sort, not _desc if on == null else on)


func _set_group(key: String) -> void:
	_group = key
	_rebuild(true)
	_sync_menus()


func _toggle_group(g: int) -> void:
	var title: String = fv.groups[g].title
	if _collapsed.has(title):
		_collapsed.erase(title)
	else:
		_collapsed[title] = true
	_rebuild(true)


func _set_preview(on = null) -> void:
	var show: bool = not %Preview.visible if on == null else on
	%Preview.visible = show
	%PreviewButton.set_pressed_no_signal(show)
	if show:
		_preview(fv.cursor_record())
	else:
		player.stop()
		_video.stop()
	_sync_menus()


func _set_numbered(on = null) -> void:
	_numbered = not _numbered if on == null else on
	fv.numbered = _numbered
	%NumberButton.set_pressed_no_signal(_numbered)
	_sync_menus()


func _pick_font() -> void:
	_font_dialog.popup_centered_ratio(0.7)


## Makes a font file the whole app's font. It's copied into the app's data folder,
## so it keeps working if the original is moved or deleted.
func _use_font(path: String) -> void:
	if not _is_font(path):  # load_dynamic_font takes any bytes, then breaks all text drawing
		status.text = "Couldn't use that as a font: " + path.get_file()
		return
	DirAccess.make_dir_recursive_absolute(FONTS)
	var dest := FONTS.path_join(path.get_file())
	if ProjectSettings.globalize_path(dest) != path and DirAccess.copy_absolute(path, dest) != OK:
		status.text = "Couldn't copy the font."
		return
	_font_path = dest
	_set_dark(P == DARK_PAL)  # rebuilds the theme with the new font
	_fit_min_size.call_deferred()
	status.text = "Font: " + path.get_file().get_basename() + "   (View > Default Font to go back)"


## True if the file starts like a font FreeType can read: TrueType, OpenType, collections,
## WOFF/WOFF2, AngelCode bitmap fonts, or Windows .fon files.
static func _is_font(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 12:
		return false
	var head := f.get_buffer(4)
	var tag := head.get_string_from_ascii()
	return head == PackedByteArray([0, 1, 0, 0]) or tag in ["true", "OTTO", "ttcf", "wOFF", "wOF2", "info", "BMF\u0003"] \
		or head.slice(0, 2).get_string_from_ascii() == "MZ"


func _reset_font() -> void:
	_font_path = ""
	_set_dark(P == DARK_PAL)
	_fit_min_size.call_deferred()
	status.text = "Back to the standard font."


func _set_sounds(on = null) -> void:
	_sounds = not _sounds if on == null else on
	_sync_menus()
	_beep(CLICK)  # a blip when switching on; silent when switching off


## Every button in the window gives a soft click (chips get theirs in _fill_chips).
func _hook_clicks(n: Node) -> void:
	if n is BaseButton and not n is MenuButton:  # menus beep when an item is picked
		n.pressed.connect(_beep.bind(CLICK))
	for c in n.get_children():
		_hook_clicks(c)


## Plays short sine tones made in code (no sound files). notes: [[hz, seconds], ...];
## a third item `true` makes that note a bell: it rings out and gets a soft octave on top.
func _beep(notes: Array) -> void:
	if not _sounds:
		return
	var key := str(notes)
	if not _sfx_cache.has(key):
		var rate := 22050
		var data := PackedByteArray()
		for n in notes:
			var count := int(rate * n[1])
			var bell: bool = n.size() > 2 and n[2]
			var at := data.size()
			data.resize(at + count * 2)
			for i in count:
				var fade := minf(1.0, minf(i, count - i) / (rate * 0.005))  # 5 ms ramps, so no pops
				var ph: float = TAU * n[0] * i / rate
				var v := sin(ph)
				if bell:
					fade *= exp(-3.5 * i / count)
					v = (v + 0.3 * sin(2 * ph)) / 1.3
				data.encode_s16(at + i * 2, int(v * fade * 0.2 * 32767))
		var w := AudioStreamWAV.new()
		w.format = AudioStreamWAV.FORMAT_16_BITS
		w.mix_rate = rate
		w.data = data
		_sfx_cache[key] = w
	_sfx.stream = _sfx_cache[key]
	_sfx.play()


## Checkbox mode: every row shows a tick box, and clicking a row toggles just that row.
func _set_checks(on = null) -> void:
	fv.checks = not fv.checks if on == null else on
	%SelectButton.set_pressed_no_signal(fv.checks)
	_sync_menus()


## null = flip. Rebuilds the whole theme from the other palette.
func _set_dark(on = null) -> void:
	if on == null:
		on = P == LIGHT_PAL
	P = DARK_PAL if on else LIGHT_PAL
	get_tree().root.theme = _win95_theme()  # root, so the dialog and popup windows get it too
	_check_on = _checkbox_icon(true)
	_check_off = _checkbox_icon(false)
	fv.check_on = _check_on
	fv.check_off = _check_off
	%Grip.texture = _grip_icon()
	%MaxButton.icon = _frame_icon(not _fullscreen())
	_sync_menus()


# --- sidebar: folders, types, skips ------------------------------------------

func _set_exts(list: Array) -> void:
	_exts.assign(list)
	_refresh_tags()


func _toggle(ext: String) -> void:
	if ext in _exts:
		_exts.erase(ext)
	else:
		_exts.append(ext)
	_refresh_tags()
	_filters_changed()


## Accepts "iso", ".ISO", "iso, log .blend". Leaves anything invalid in the box.
func _add_custom() -> void:
	var bad := PackedStringArray()
	for raw in custom_edit.text.replace(",", " ").split(" ", false):
		var ext := raw.lstrip(".").to_lower()
		if ext.is_empty() or "." in ext or not ext.is_valid_filename():
			bad.append(raw)
		elif ext not in _exts:
			_exts.append(ext)
	custom_edit.text = " ".join(bad)
	if not bad.is_empty():
		status.text = "Not a file extension: " + ", ".join(bad)
	_refresh_tags()
	_filters_changed()


func _refresh_tags() -> void:
	_fill_chips(tags, _exts, _toggle, "(all files)", func(e: String) -> String: return e)
	for i in presets.item_count:
		if not presets.is_item_separator(i):
			presets.set_item_checked(i, presets.get_item_text(i) in _exts)


func _add_skip() -> void:
	for raw in %SkipEdit.text.split(",", false):
		var s: String = raw.strip_edges()
		if s != "" and s not in _skips:
			_skips.append(s)
	%SkipEdit.clear()
	_refresh_skips()
	_filters_changed()


func _remove_skip(s: String) -> void:
	_skips.erase(s)
	_refresh_skips()
	_filters_changed()


func _refresh_skips() -> void:
	_fill_chips(skips_box, _skips, _remove_skip, "(nothing skipped)", func(s: String) -> String: return s)


## Rebuilds a row of removable "name  x" chip buttons (or a hint label when empty).
func _fill_chips(box: HFlowContainer, items: Array, remove: Callable, empty: String, label: Callable) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	for item in items:
		var b := Button.new()
		b.text = label.call(item) + "  x"
		b.tooltip_text = "Remove " + item
		b.pressed.connect(remove.bind(item))
		b.pressed.connect(_beep.bind(CLICK))
		box.add_child(b)
	if items.is_empty():
		var l := Label.new()
		l.text = empty
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 150
		box.add_child(l)


func _norm(path: String) -> String:
	# Explorer's "Copy as path" wraps paths in quotes; drop them.
	path = path.strip_edges().lstrip("\"'").rstrip("\"'").strip_edges().replace("\\", "/").simplify_path()
	return path if path.ends_with(":/") or path.length() > 3 else path.trim_suffix("/") + "/"


## Adds a folder to scan. Returns false (and says why) if it isn't one.
func _add_folder(path: String) -> bool:
	path = _norm(path)
	if not DirAccess.dir_exists_absolute(path):
		status.text = "Folder not found: " + path
		return false
	if not _roots.any(func(r: String) -> bool: return r.nocasecmp_to(path) == 0):
		_roots.append(path)
		_refresh_folders()
		_filters_changed()
	return true


func _remove_folder(path: String) -> void:
	_roots.erase(path)
	_refresh_folders()
	_filters_changed()


## Add button: adds the typed path, or opens the folder picker when the box is empty.
func _add_typed_folder() -> void:
	if path_edit.text.strip_edges() == "":
		_browse()
	elif _add_folder(path_edit.text):
		path_edit.clear()


## Folders, types or skips changed: rescan shortly (the list follows the settings on its own).
func _filters_changed() -> void:
	if _roots.is_empty():
		_rescan.stop()
		_escape_scan()
		_set_records({})
		_rebuild(false)
		return
	_rescan.start()


func _auto_scan() -> void:
	if _phase != "":
		_rescan_pending = true
	else:
		_start_scan(not _path.is_empty())  # keep showing the current list if there is one


func _escape_scan() -> void:
	if _phase != "":
		_abort = true


func _refresh_folders() -> void:
	# Chip shows the folder's own name (or "D:" for a drive); tooltip has the full path.
	_fill_chips(folders, _roots, _remove_folder, "(none yet: press Browse..., or drop folders here)",
		func(r: String) -> String: return r.get_file() if r.get_file() != "" else r.trim_suffix("/"))


## Dropping folders adds them; dropping a file adds the folder it lives in.
func _on_dropped(paths: PackedStringArray) -> void:
	var added := 0
	for p in paths:
		if p.get_extension().to_lower() in FONT_EXT:  # a dropped font file becomes the UI font
			_use_font(p)
			continue
		if _add_folder(p if DirAccess.dir_exists_absolute(p) else p.get_base_dir()):
			added += 1
	status.text = "Added %d folder%s." % [added, "" if added == 1 else "s"]


func _on_dir_chosen(dir: String) -> void:
	if _dialog_purpose == "add":
		_add_folder(dir)
	else:
		_start_collect(_pending_recs, dir, _dialog_purpose == "move")


## Drops folders already covered by another root, so nothing is listed twice.
func _scan_roots() -> PackedStringArray:
	var out := PackedStringArray()
	for r in _roots:
		var inside := _roots.any(func(o: String) -> bool:
			return o != r and r.to_lower().begins_with(o.to_lower().trim_suffix("/") + "/"))
		if not inside and DirAccess.dir_exists_absolute(r):
			out.append(r)
	return out


# --- scanning ----------------------------------------------------------------

## quiet: keep showing the current list and swap in the fresh one at the end (used at startup).
func _start_scan(quiet := false) -> void:
	if _phase != "":
		return
	if path_edit.text.strip_edges() != "":  # a typed-but-not-added path counts too
		_add_typed_folder()
	_rescan.stop()  # this scan already uses the latest settings
	_rescan_pending = false
	var roots := _scan_roots()
	if roots.is_empty():
		if _roots.is_empty():
			status.text = "Pick a folder to scan."
			_browse()
		else:
			status.text = "None of the folders exist right now."
		return
	_join_thread()
	var exts := {}  # fresh copies for the worker; the UI can edit the originals mid-scan
	for ext in _exts:
		exts[ext] = true
	var prev := {}
	for f in FIELDS:
		prev[f] = get(f).duplicate()  # last scan's details, reused for files that haven't changed
	_leave_dupes(false)
	_gen += 1
	_abort = false
	_phase = "scan"
	_dirs = 0
	_details_done = 0
	scan_button.text = "Stop"
	if not quiet:
		_set_records({})
		_rebuild(false)
	status.text = "Checking for changes..." if quiet else "Scanning..."
	_thread.start(_scan.bind(_gen, roots, exts, PackedStringArray(_skips), quiet, prev))


func _join_thread() -> void:
	if _thread.is_started():
		_abort = true
		_thread.wait_to_finish()


## Worker thread: walk the folders, then read size, date and tags of each file.
func _scan(gen: int, roots: PackedStringArray, exts: Dictionary, skip: PackedStringArray, quiet: bool, prev: Dictionary) -> void:
	var stack := roots
	var found := PackedStringArray()
	var batch := PackedStringArray()
	var dirs := 0
	while not stack.is_empty() and not _abort:
		var dir := stack[-1]
		stack.resize(stack.size() - 1)
		dirs += 1
		for f in DirAccess.get_files_at(dir):
			if exts.is_empty() or exts.has(f.get_extension().to_lower()):
				batch.append(dir.path_join(f))
		for d in DirAccess.get_directories_at(dir):
			if not Array(skip).any(func(s: String) -> bool: return d.matchn(s)):
				stack.append(dir.path_join(d))
		if batch.size() >= BATCH and not quiet:
			_found.call_deferred(gen, batch, dirs)
			found.append_array(batch)
			batch = PackedStringArray()
	found.append_array(batch)
	if not quiet:
		_found.call_deferred(gen, batch, dirs)
	if _abort:
		_scan_done.call_deferred(gen)
		return
	_phase_details.call_deferred(gen)
	var old := {}  # path -> index into prev
	for i in prev._path.size():
		old[prev._path[i]] = i
	var all := _empty_cols()
	for start in range(0, found.size(), BATCH):
		var cols := _empty_cols()
		for p in found.slice(start, start + BATCH):
			if _abort:
				_scan_done.call_deferred(gen)
				return
			var m := FileAccess.get_modified_time(p)
			var o: int = old.get(p, -1)
			if o >= 0 and prev._mtime[o] == m:  # unchanged since last scan: reuse
				for f in FIELDS:
					cols[f].append(prev[f][o])
				continue
			var t := Tags.read(p) if p.get_extension().to_lower() in Tags.AUDIO else {}
			cols._path.append(p)
			cols._size.append(FileAccess.get_size(p))
			cols._mtime.append(m)
			for k in ["title", "artist", "album", "year", "track"]:
				cols["_" + k].append(t.get(k, ""))
			cols._length.append(t.get("length", 0.0))
			cols._kbps.append(t.get("bitrate", 0))
		if quiet:
			for f in FIELDS:
				all[f].append_array(cols[f])
		else:
			_details.call_deferred(gen, start, cols)
	if quiet:
		_replace_all.call_deferred(gen, all, dirs)
	_scan_done.call_deferred(gen)


static func _empty_cols() -> Dictionary:
	return {_path = PackedStringArray(), _size = PackedInt64Array(), _mtime = PackedInt64Array(),
		_title = PackedStringArray(), _artist = PackedStringArray(), _album = PackedStringArray(),
		_year = PackedStringArray(), _track = PackedStringArray(), _length = PackedFloat32Array(), _kbps = PackedInt32Array()}


## Replaces every record column at once (cols empty = clear).
func _set_records(cols: Dictionary) -> void:
	for f in FIELDS:
		set(f, cols[f] if cols.has(f) else _empty_cols()[f])


func _found(gen: int, paths: PackedStringArray, dirs: int) -> void:
	if gen != _gen:
		return
	var n := _path.size()
	_path.append_array(paths)
	var m := _path.size()
	_size.resize(m); _mtime.resize(m); _title.resize(m); _artist.resize(m); _album.resize(m)
	_year.resize(m); _track.resize(m); _length.resize(m); _kbps.resize(m)
	for i in range(n, m):
		_size[i] = -1
	_dirs = dirs
	if not _live_dirty:  # re-list at most every 0.3 s while files pour in
		_live_dirty = true
		get_tree().create_timer(0.3).timeout.connect(func() -> void:
			_live_dirty = false
			if gen == _gen and _path.size() <= LIVE_LIMIT:
				_rebuild(true))
	status.text = "Scanning...  %s files in %s folders" % [_num(_path.size()), _num(dirs)]


func _phase_details(gen: int) -> void:
	if gen == _gen and _phase == "scan":
		_phase = "details"
		_rebuild(true)


func _details(gen: int, start: int, cols: Dictionary) -> void:
	if gen != _gen:
		return
	for i in cols._path.size():
		var r: int = start + i
		_size[r] = cols._size[i]; _mtime[r] = cols._mtime[i]; _title[r] = cols._title[i]
		_artist[r] = cols._artist[i]; _album[r] = cols._album[i]; _year[r] = cols._year[i]
		_track[r] = cols._track[i]; _length[r] = cols._length[i]; _kbps[r] = cols._kbps[i]
	_details_done = start + cols._path.size()
	status.text = "Reading details...  %s / %s" % [_num(_details_done), _num(_path.size())]
	fv.queue_redraw()


func _replace_all(gen: int, cols: Dictionary, dirs: int) -> void:
	if gen != _gen:
		return
	_set_records(cols)
	_dirs = dirs
	_rebuild(true)


func _scan_done(gen: int) -> void:
	if gen != _gen:
		return
	_thread.wait_to_finish()
	var stopped := _abort
	_phase = ""
	scan_button.text = "Scan"
	_rebuild(true)
	if not stopped:
		_save_index()
	_update_status("Stopped." if stopped else "Done.")
	if not stopped:
		_beep(DONE)
	if _rescan_pending:
		_rescan_pending = false
		_start_scan(true)


# --- the list: filter, sort, group -------------------------------------------

## Re-derives the visible rows from the records: search filter, then sort, then group headers.
func _rebuild(keep := true) -> void:
	var rows := _filtered()
	var dupes := not _dupe_sets.is_empty()
	var group := "dupes" if dupes else _group
	# Sorting uses string keys and the engine's own sort: about 1 s per million files.
	var keys := PackedStringArray()
	keys.resize(rows.size())
	for n in rows.size():
		var r := rows[n]
		keys[n] = (_group_key(r, group) if group != "none" else "") + char(1) + _sort_key(r, _sort) \
			+ char(1) + _path[r].get_file().to_lower() + char(1) + str(r)
	keys.sort()
	var groups: Array = []
	var out := PackedInt32Array()
	var run := PackedInt32Array()
	var run_key := ""
	for n in keys.size() + 1:
		var gk := keys[n].get_slice(char(1), 0) if n < keys.size() else char(2)
		if n > 0 and (gk != run_key or n == keys.size()):
			_emit_run(run, run_key, group, groups, out)
			run = PackedInt32Array()
		if n < keys.size():
			run_key = gk
			run.append(keys[n].get_slice(char(1), 3).to_int())
	fv.empty_text = _empty_text()
	fv.set_data(out, groups, _path.size(), keep)
	_shown_n = 0
	_shown_bytes = 0
	for r in out:
		if r >= 0:
			_shown_n += 1
			_shown_bytes += maxi(_size[r], 0)
	_update_status()


## What the empty list says, so it's always clear what to do next.
func _empty_text() -> String:
	if _roots.is_empty():
		return "No folders yet.\n\nPress  Browse...  (top left), or drop a folder onto this window.\nIts files will be listed here."
	if _phase == "scan" and _path.is_empty():
		return "Scanning..."
	if _path.is_empty():
		return "No matching files in these folders.\n\nCheck the file types on the left, or press  Clear types  to list every file."
	if search.text.strip_edges() != "":
		return "Nothing matches \"%s\"." % search.text.strip_edges()
	return ""


## Appends one group's rows (reversed for descending, behind a header when grouping).
func _emit_run(run: PackedInt32Array, key: String, group: String, groups: Array, out: PackedInt32Array) -> void:
	if _desc:
		run.reverse()
	if group == "none":
		out.append_array(run)
		return
	var title := _group_title(run[0], key, group)
	var folded := _collapsed.has(title)
	groups.append({title = title, count = run.size(), collapsed = folded})
	out.append(-groups.size())
	if not folded:
		out.append_array(run)


func _filtered() -> PackedInt32Array:
	var q := search.text.strip_edges().to_lower()
	var wild := "*" in q or "?" in q
	var words := q.split(" ", false)
	var out := PackedInt32Array()
	var dupes := not _dupe_sets.is_empty()
	for i in _path.size():
		if dupes and not _dupe_of.has(_path[i]):
			continue
		if q != "":
			var name := _path[i].get_file()
			if wild:
				if not name.matchn(q):
					continue
			else:
				var hay := (name + "\n" + _artist[i] + "\n" + _album[i] + "\n" + _title[i]).to_lower()
				var hit := true
				for w in words:
					if not hay.contains(w):
						hit = false
						break
				if not hit:
					continue
		out.append(i)
	return out


func _sort_key(i: int, key: String) -> String:
	match key:
		"name": return _path[i].get_file().to_lower()
		"type": return _path[i].get_extension().to_lower()
		"folder": return _path[i].get_base_dir().to_lower()
		"size": return "%015d" % maxi(_size[i], 0)
		"modified": return "%015d" % _mtime[i]
		"length": return "%09d" % int(_length[i] * 1000)
		"track": return "%06d" % _track[i].to_int()
		"year": return _year[i]
	return get("_" + key)[i].to_lower()


func _group_key(i: int, group: String) -> String:
	match group:
		"folder": return _path[i].get_base_dir().to_lower()
		"type": return _path[i].get_extension().to_lower()
		"dupes": return "%08d" % _dupe_of[_path[i]]
	return get("_" + group)[i].to_lower()


func _group_title(i: int, key: String, group: String) -> String:
	match group:
		"folder": return _path[i].get_base_dir()
		"type": return "." + key.to_upper() if key != "" else "(no extension)"
		"dupes": return "Copy set %d  -  %s each" % [_dupe_of[_path[i]] + 1, _human(_size[i])]
	var v: String = get("_" + group)[i]
	return v if v != "" else "(no %s)" % group


## What the list shows for a record in a given column.
func _cell(rec: int, key: String) -> String:
	match key:
		"name": return _path[rec].get_file()
		"path": return _path[rec]
		"type": return _path[rec].get_extension().to_lower()
		"folder": return _path[rec].get_base_dir()
		"size": return _human(_size[rec]) if _size[rec] >= 0 else ""
		"modified": return _date(_mtime[rec]) if _mtime[rec] > 0 else ""
		"length": return _dur(_length[rec]) if _length[rec] > 0 else ""
		"bitrate": return str(_kbps[rec]) if _kbps[rec] > 0 else ""
	return get("_" + key)[rec]


func _update_status(tail := "") -> void:
	var none := fv.sel.count(1) == 0
	%CopyToButton.disabled = none  # the toolbar's Copy To / Move To only work on a selection
	%MoveToButton.disabled = none
	var parts := ["%s files" % _num(_path.size())]
	if _shown_n != _path.size():
		parts.append("%s shown" % _num(_shown_n))
	var sel := fv.sel.count(1)
	if sel > 0:
		parts.append("%s selected" % _num(sel))
	if _shown_bytes > 0:
		parts.append(_human(_shown_bytes))
	if not _dupe_sets.is_empty():
		parts.append("DUPLICATES VIEW (Esc to leave)")
	if _phase == "details":
		parts.append("reading details %d%%" % (100 * _details_done / maxi(_path.size(), 1)))
	if tail != "":
		parts.append(tail)
	status.text = "   ".join(parts)


static func _num(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(-3)
	return s + out


static func _human(b: int) -> String:
	if b < 1024:
		return "%d B" % b
	var units := ["KB", "MB", "GB", "TB"]
	var v := b / 1024.0
	var u := 0
	while v >= 1024 and u < units.size() - 1:
		v /= 1024.0
		u += 1
	return "%.1f %s" % [v, units[u]]


static func _date(unix: int) -> String:
	var local: int = unix + Time.get_time_zone_from_system().bias * 60
	return Time.get_datetime_string_from_unix_time(local, true).left(16)


static func _dur(s: float) -> String:
	var t := int(s)
	return "%d:%02d:%02d" % [t / 3600, t / 60 % 60, t % 60] if t >= 3600 else "%d:%02d" % [t / 60, t % 60]


# --- thumbnails (Tiles view) -------------------------------------------------

## Texture for a tile, or null. Missing ones are made on the thread pool and cached on disk.
func _thumb(rec: int) -> Texture2D:
	var p := _path[rec]
	if _thumbs.has(p):
		return _thumbs[p]
	var ext := p.get_extension().to_lower()
	if ext in IMAGE_EXT or ext in Tags.AUDIO or ext in VIDEO_EXT:
		if _thumbs.size() > 3000:  # keeps memory bounded on huge libraries
			_thumbs.clear()
		_thumbs[p] = null
		_thumb_tasks.append(WorkerThreadPool.add_task(_make_thumb.bind(p, _mtime[rec])))
	return null


func _make_thumb(p: String, mtime: int) -> void:
	var cache := THUMBS.path_join((p + str(mtime)).md5_text() + ".png")
	var img: Image
	if FileAccess.file_exists(cache):
		img = Image.load_from_file(cache)
	else:
		img = _cover_image(p)
		if img:
			var s := img.get_size()
			var k := minf(FileView.THUMB / float(s.x), FileView.THUMB / float(s.y))
			if k < 1:
				img.resize(maxi(1, int(s.x * k)), maxi(1, int(s.y * k)), Image.INTERPOLATE_LANCZOS)
			img.save_png(cache)
	if img:
		_thumb_ready.call_deferred(p, img)


func _thumb_ready(p: String, img: Image) -> void:
	_thumbs[p] = ImageTexture.create_from_image(img)
	fv.queue_redraw()


## The picture for a file: the image itself, a song's embedded cover, or its folder's cover.jpg.
func _cover_image(p: String) -> Image:
	var ext := p.get_extension().to_lower()
	if ext in IMAGE_EXT:
		var img := Image.new()
		return img if img.load(p) == OK else null
	if ext in VIDEO_EXT:
		return _video_frame(p)
	if ext in Tags.AUDIO:
		var img := _image_from_bytes(Tags.read(p, true).get("art", PackedByteArray()))
		if img:
			return img
		for name in FOLDER_ART:
			var f := p.get_base_dir().path_join(name)
			if FileAccess.file_exists(f):
				var fimg := Image.new()
				if fimg.load(f) == OK:
					return fimg
	return null


## One frame from a video (1 s in, or the first frame of very short clips), via ffmpeg; null without it.
func _video_frame(p: String) -> Image:
	var ff := _find_ffmpeg()
	if ff == "":
		return null
	var tmp := ProjectSettings.globalize_path(THUMBS.path_join("frame_%s.png" % (p + str(Time.get_ticks_usec())).md5_text()))
	for at in ["1", "0"]:
		OS.execute(ff, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-ss", at, "-i", p,
			"-frames:v", "1", "-vf", "scale='min(640,iw)':-2", tmp])
		if FileAccess.file_exists(tmp):
			var img := Image.load_from_file(tmp)
			DirAccess.remove_absolute(tmp)
			return img
	return null


## Length, picture size and codec of a video, read from ffmpeg's description of the file.
func _video_info(p: String) -> Dictionary:
	var ff := _find_ffmpeg()
	var d := {}
	if ff == "":
		return d
	var out := []
	OS.execute(ff, ["-hide_banner", "-nostdin", "-i", p], out, true)  # no output file: ffmpeg just describes it
	var text: String = out[0] if out.size() else ""
	var m := RegEx.create_from_string("Duration: (\\d+):(\\d+):([\\d.]+)").search(text)
	if m:
		d.length = m.get_string(1).to_int() * 3600 + m.get_string(2).to_int() * 60 + m.get_string(3).to_float()
	m = RegEx.create_from_string("Video: (\\w+).*?, (\\d{2,5})x(\\d{2,5})").search(text)
	if m:
		d.codec = m.get_string(1)
		d.size = Vector2i(m.get_string(2).to_int(), m.get_string(3).to_int())
	return d


static func _image_from_bytes(b: PackedByteArray) -> Image:
	if b.size() < 12:
		return null
	var img := Image.new()
	var err := FAILED
	if b[0] == 0xFF and b[1] == 0xD8:
		err = img.load_jpg_from_buffer(b)
	elif b[0] == 0x89 and b[1] == 0x50:
		err = img.load_png_from_buffer(b)
	elif b.slice(8, 12).get_string_from_ascii() == "WEBP":
		err = img.load_webp_from_buffer(b)
	return img if err == OK else null


# --- preview pane ------------------------------------------------------------

func _preview(rec: int) -> void:
	if not %Preview.visible:
		return
	if rec == _preview_rec and rec >= 0:
		return
	_preview_rec = rec
	player.stop()
	player.stream = null
	_video.stop()
	_video_size = Vector2i.ZERO
	%PlayButton.text = "Play"
	for n in ["%PreviewImage", "%AudioRow", "%PreviewText"]:
		get_node(n).visible = false
	if rec < 0 or rec >= _path.size():
		%PreviewTitle.text = "Nothing selected"
		%PreviewInfo.text = ""
		return
	var p := _path[rec]
	var ext := p.get_extension().to_lower()
	%PreviewTitle.text = p.get_file()
	var img := _cover_image(p)
	var info := PackedStringArray([
		"Type: " + (ext.to_upper() if ext != "" else "(none)"),
		"Size: " + (_human(_size[rec]) if _size[rec] >= 0 else "..."),
		"Modified: " + (_date(_mtime[rec]) if _mtime[rec] > 0 else "..."),
	])
	if img:
		info.append("Picture: %d x %d" % [img.get_width(), img.get_height()])
		var s := img.get_size()
		if maxi(s.x, s.y) > 1024:
			var k := 1024.0 / maxi(s.x, s.y)
			img.resize(int(s.x * k), int(s.y * k), Image.INTERPOLATE_BILINEAR)
		%PreviewImage.texture = ImageTexture.create_from_image(img)
		%PreviewImage.visible = true
	for k in ["artist", "album", "title", "track", "year"]:
		var v: String = get("_" + k)[rec]
		if v != "":
			info.append("%s: %s" % [k.capitalize(), v])
	if _length[rec] > 0:
		info.append("Length: %s   %d kbps" % [_dur(_length[rec]), _kbps[rec]])
	if ext in VIDEO_EXT:
		var v := _video_info(p)
		if v.has("size"):
			info.append("Video: %d x %d  %s" % [v.size.x, v.size.y, str(v.get("codec", "")).to_upper()])
			var k := minf(1.0, minf(VIDEO_MAX.x / float(v.size.x), VIDEO_MAX.y / float(v.size.y)))
			_video_size = Vector2i(maxi(2, int(v.size.x * k) / 2 * 2), maxi(2, int(v.size.y * k) / 2 * 2))
			%AudioRow.visible = true
			%Seek.max_value = maxf(v.get("length", 0.0), 0.1)
			%Seek.value = 0
			%TimeLabel.text = "0:00 / " + _dur(v.get("length", 0.0))
		if v.has("length"):
			info.append("Length: " + _dur(v.length))
		if _find_ffmpeg() == "":
			info.append("Playing videos here needs the free ffmpeg (ffmpeg.org). Enter opens it in your video player.")
	elif ext in PLAYABLE:
		%AudioRow.visible = true
		%Seek.max_value = maxf(_length[rec], 0.1)
		%Seek.value = 0
		%TimeLabel.text = "0:00 / " + _dur(_length[rec])
	elif not img and ext not in Tags.AUDIO:
		var text := _peek_text(p)
		if text != "":
			%PreviewText.text = text
			%PreviewText.visible = true
	info.append("Folder: " + p.get_base_dir())
	%PreviewInfo.text = "\n".join(info)


## First 200 lines of a file that looks like text (no NUL bytes up front), else "".
static func _peek_text(p: String) -> String:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return ""
	var b := f.get_buffer(65536)
	if b.slice(0, 4096).has(0):
		return ""
	var lines := b.get_string_from_utf8().split("\n")
	return "\n".join(lines.slice(0, 200))


func _toggle_play() -> void:
	var rec := _preview_rec
	if %Preview.visible and _video_size != Vector2i.ZERO:
		if not _video.playing:
			_play_video(%Seek.value if %Seek.value < %Seek.max_value - 0.5 else 0.0)
		else:
			_video.set_paused(not _video.paused)
		%PlayButton.text = "Pause" if _video.playing and not _video.paused else "Play"
		return
	if not %Preview.visible or rec < 0 or _path[rec].get_extension().to_lower() not in PLAYABLE:
		return
	if player.stream == null:
		var p := _path[rec]
		match p.get_extension().to_lower():
			"mp3": player.stream = AudioStreamMP3.load_from_file(p)
			"ogg": player.stream = AudioStreamOggVorbis.load_from_file(p)
			"wav": player.stream = AudioStreamWAV.load_from_file(p)
		if player.stream == null:
			status.text = "Can't play this file."
			return
		%Seek.max_value = player.stream.get_length()
		player.play()
	elif player.stream_paused or not player.playing:
		player.stream_paused = false
		if not player.playing:
			player.play(%Seek.value)
	else:
		player.stream_paused = true
	%PlayButton.text = "Pause" if player.playing and not player.stream_paused else "Play"


func _play_video(from: float) -> void:
	if not _video.play(_find_ffmpeg(), _path[_preview_rec], from, _video_size):
		status.text = "Couldn't start the video."
		return
	%PlayButton.text = "Pause"


# --- export ------------------------------------------------------------------

## The files an action works on: the selection, or everything listed when nothing is selected.
func _export_recs() -> PackedInt32Array:
	var s := fv.selected()
	return s if not s.is_empty() else _shown()


func _export(kind: String) -> void:
	if _shown().is_empty():
		status.text = "Nothing to export yet."
		return
	_save_kind = kind
	save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	save_dialog.filters = PackedStringArray(["*.m3u8 ; M3U playlist (UTF-8)", "*.m3u ; M3U playlist"]
		if kind == "m3u" else ["*.csv ; CSV spreadsheet"])
	save_dialog.current_file = "Tune-O-Viewer list." + ("m3u8" if kind == "m3u" else "csv")
	save_dialog.title = "Export Playlist" if kind == "m3u" else "Export List"
	save_dialog.popup_centered_ratio(0.7)


func _write_export(dest: String) -> void:
	if dest.get_extension() == "":
		dest += ".m3u8" if _save_kind == "m3u" else ".csv"
	var recs := _export_recs()
	var lines := PackedStringArray()
	if _save_kind == "m3u":
		lines.append("#EXTM3U")
		for r in recs:
			var label := ("%s - %s" % [_artist[r], _title[r]]) if _artist[r] != "" and _title[r] != "" else _path[r].get_file().get_basename()
			lines.append("#EXTINF:%d,%s" % [roundi(_length[r]) if _length[r] > 0 else -1, label])
			lines.append(_path[r].replace("/", "\\") if OS.get_name() == "Windows" else _path[r])
	else:
		lines.append("name,type,size_bytes,modified,length_seconds,title,artist,album,track,year,kbps,folder,path")
		for r in recs:
			var row := [_path[r].get_file(), _path[r].get_extension(), str(_size[r]),
				_date(_mtime[r]) if _mtime[r] > 0 else "", "%.1f" % _length[r] if _length[r] > 0 else "",
				_title[r], _artist[r], _album[r], _track[r], _year[r], str(_kbps[r]) if _kbps[r] > 0 else "",
				_path[r].get_base_dir(), _path[r]]
			lines.append(",".join(PackedStringArray(row.map(_csv))))
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f == null:
		status.text = "Couldn't write " + dest
		return
	f.store_string(("﻿" if _save_kind == "csv" else "") + "\n".join(lines) + "\n")  # BOM: Excel reads UTF-8 right
	status.text = "Exported %s files to %s" % [_num(recs.size()), dest]


static func _csv(v: String) -> String:
	return "\"%s\"" % v.replace("\"", "\"\"") if v.contains(",") or v.contains("\"") or v.contains("\n") else v


# --- duplicates --------------------------------------------------------------

func _find_dupes() -> void:
	if _job.is_started() or _phase != "":
		status.text = "Busy - try again when the current task finishes."
		return
	if _path.is_empty():
		status.text = "Scan some folders first."
		return
	_job_abort = false
	status.text = "Looking for duplicates..."
	_job.start(_dupe_job.bind(_path.duplicate(), _size.duplicate()))


## Worker: same size -> same first 64 KB -> same full MD5. Each stage only looks at what survived the last.
func _dupe_job(paths: PackedStringArray, sizes: PackedInt64Array) -> void:
	var by_size := {}
	for i in paths.size():
		var s := sizes[i] if sizes[i] >= 0 else FileAccess.get_size(paths[i])
		if s > 0:
			if not by_size.has(s):
				by_size[s] = PackedInt32Array()
			by_size[s].append(i)
	var sets: Array = []
	var todo := by_size.values().filter(func(g: PackedInt32Array) -> bool: return g.size() > 1)
	for n in todo.size():
		if _job_abort:
			break
		var heads := _split_by(todo[n], func(i: int) -> String: return _head_md5(paths[i]))
		for g in heads:
			var full := [g] if FileAccess.get_size(paths[g[0]]) <= 65536 else _split_by(g, func(i: int) -> String: return FileAccess.get_md5(paths[i]))
			for s in full:
				var ps := PackedStringArray()
				for i in s:
					ps.append(paths[i])
				sets.append(ps)
		if n % 50 == 0:
			_job_progress.call_deferred("Looking for duplicates...  %d%%" % (100 * n / todo.size()))
	_dupes_done.call_deferred(sets)


static func _split_by(g: PackedInt32Array, hash: Callable) -> Array:
	var by := {}
	for i in g:
		var h: String = hash.call(i)
		if h != "":
			if not by.has(h):
				by[h] = PackedInt32Array()
			by[h].append(i)
	return by.values().filter(func(x: PackedInt32Array) -> bool: return x.size() > 1)


static func _head_md5(p: String) -> String:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(f.get_buffer(65536))
	return ctx.finish().hex_encode()


func _job_progress(text: String) -> void:
	status.text = text


func _dupes_done(sets: Array) -> void:
	_job.wait_to_finish()
	if sets.is_empty():
		status.text = "No duplicate files found."
		return
	_dupe_sets = sets
	_dupe_of.clear()
	var files := 0
	var wasted := 0
	for n in sets.size():
		for p in sets[n]:
			_dupe_of[p] = n
		files += sets[n].size()
		wasted += (sets[n].size() - 1) * FileAccess.get_size(sets[n][0])
	_rebuild(false)
	_update_status("%d copy sets, %s could be freed. Edit > Select Extra Copies picks all but one of each." % [sets.size(), _human(wasted)])


func _leave_dupes(rebuild := true) -> void:
	if _dupe_sets.is_empty():
		return
	_dupe_sets = []
	_dupe_of.clear()
	if rebuild:
		_rebuild(false)


## In the duplicates view: select every copy except the first of each set.
func _select_extra_copies() -> void:
	if _dupe_sets.is_empty():
		status.text = "Use Edit > Find Duplicates first."
		return
	var seen := {}
	var pick := PackedInt32Array()
	for r in _shown():
		var s: int = _dupe_of[_path[r]]
		if seen.has(s):
			pick.append(r)
		seen[s] = true
	fv.set_selected(pick)


# --- copy / move / recycle ---------------------------------------------------

func _collect(move: bool) -> void:
	var recs := _targets()
	if recs.is_empty():
		status.text = "Select some files first."
		return
	if _job.is_started():
		status.text = "Busy - try again when the current task finishes."
		return
	_pending_recs = recs
	_dialog_purpose = "move" if move else "copy"
	dialog.title = "%s %d files to..." % ["Move" if move else "Copy", recs.size()]
	dialog.popup_centered_ratio(0.7)


func _start_collect(recs: PackedInt32Array, dest: String, move: bool) -> void:
	var paths := PackedStringArray()
	for r in recs:
		paths.append(_path[r])
	var go := func() -> void:
		_job_abort = false
		_job.start(_collect_job.bind(recs, paths, dest, move))
	if move:
		_ask("Move %d files into\n%s ?" % [recs.size(), dest], go)
	else:
		go.call()


## Worker: copy or move files into one folder, never overwriting ("song (2).mp3").
func _collect_job(recs: PackedInt32Array, paths: PackedStringArray, dest: String, move: bool) -> void:
	var moved := {}  # rec -> new path
	var failed := 0
	for n in paths.size():
		if _job_abort:
			break
		var src := paths[n]
		var target := dest.path_join(src.get_file())
		var k := 2
		while FileAccess.file_exists(target):
			target = dest.path_join("%s (%d).%s" % [src.get_file().get_basename(), k, src.get_extension()])
			k += 1
		var err := DirAccess.rename_absolute(src, target) if move else DirAccess.copy_absolute(src, target)
		if move and err != OK and DirAccess.copy_absolute(src, target) == OK:  # different drive
			err = DirAccess.remove_absolute(src)
		if err == OK:
			moved[recs[n]] = target
		else:
			failed += 1
		if n % 20 == 0:
			_job_progress.call_deferred("%s...  %d / %d" % ["Moving" if move else "Copying", n, paths.size()])
	_collect_done.call_deferred(moved, failed, dest, move)


func _collect_done(moved: Dictionary, failed: int, dest: String, move: bool) -> void:
	_job.wait_to_finish()
	if move:
		for r in moved:
			_path[r] = moved[r]
		_index_dirty = true
		_rebuild(true)
	status.text = "%s %d files to %s%s" % ["Moved" if move else "Copied", moved.size(), dest,
		"  (%d failed)" % failed if failed else ""]


# --- rename ------------------------------------------------------------------

func _build_rename() -> void:
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = 360
	box.add_child(_rename_note)
	box.add_child(_rename_edit)
	_rename.add_child(box)
	_rename.ok_button_text = "Rename"
	_rename.add_button("Skip", true, "skip")
	_rename.register_text_enter(_rename_edit)  # Enter = Rename
	_rename.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	_rename.confirmed.connect(_rename_apply)
	_rename.canceled.connect(func() -> void: _rename_finish())
	_rename.custom_action.connect(func(_a: StringName) -> void:
		_rename.hide()
		_rename_advance())
	add_child(_rename)


## F2: renames the selected files one at a time, in list order. Skip leaves one as is; Cancel stops.
func _rename_start() -> void:
	var recs := _targets()
	if recs.is_empty():
		status.text = "Select a file to rename."
		return
	_rename_queue = recs
	_rename_total = recs.size()
	_renamed = 0
	_rename_show()


func _rename_show(error := "") -> void:
	var name := _path[_rename_queue[0]].get_file()
	var n := _rename_total - _rename_queue.size() + 1
	_rename.title = "Rename" if _rename_total == 1 else "Rename file %d of %d" % [n, _rename_total]
	_rename_note.text = (error + "\n" if error != "" else "") + "New name for  " + name
	if error == "":
		_rename_edit.text = name
	_rename.popup_centered()
	_rename_edit.grab_focus()
	_rename_edit.select(0, name.get_basename().length() if error == "" else _rename_edit.text.length())  # like Explorer: name, not extension


func _rename_apply() -> void:
	var r := _rename_queue[0]
	var old := _path[r]
	var new := _rename_edit.text.strip_edges()
	if new == old.get_file():
		_rename_advance()
		return
	var target := old.get_base_dir().path_join(new)
	var error := ""
	if new == "" or not new.is_valid_filename():
		error = "That name can't be used (it can't contain \\ / : * ? \" < > |)."
	elif FileAccess.file_exists(target) and target.to_lower() != old.to_lower():  # case-only changes are fine
		error = "A file called %s is already in that folder." % new
	elif DirAccess.rename_absolute(old, target) != OK:
		error = "Windows wouldn't rename it (is it open in another program?)."
	if error != "":
		_rename_show.call_deferred(error)  # the dialog closes itself on OK; bring it back
		return
	_path[r] = target
	_renamed += 1
	_index_dirty = true
	if _preview_rec == r:
		_preview_rec = -1
		_preview(r)
	_rename_advance()


func _rename_advance() -> void:
	_rename_queue.remove_at(0)
	if _rename_queue.is_empty():
		_rename_finish()
	else:
		_rename_show.call_deferred()


func _rename_finish() -> void:
	_rename_queue.clear()
	if _renamed > 0:
		_rebuild(true)
	status.text = "Renamed %d of %d file%s." % [_renamed, _rename_total, "" if _rename_total == 1 else "s"]


# --- convert -----------------------------------------------------------------

## Converts the selection to another format, saved next to each original (never overwriting).
func _convert(fmt: String) -> void:
	var recs := _targets()
	if recs.is_empty():
		status.text = "Select some files to convert."
		return
	if _job.is_started():
		status.text = "Busy - try again when the current task finishes."
		return
	var ffmpeg := ""
	if fmt in AUDIO_OUT:
		ffmpeg = _find_ffmpeg()
		if ffmpeg == "":
			_ask("Converting audio uses ffmpeg, a free program that isn't installed here.\n"
				+ "Open ffmpeg.org to download it?", func() -> void: OS.shell_open("https://ffmpeg.org/download.html"))
			return
	var paths := PackedStringArray()
	for r in recs:
		paths.append(_path[r])
	_job_abort = false
	_job.start(_convert_job.bind(paths, fmt, ffmpeg))


## ffmpeg on the PATH (where/which), or "".
func _find_ffmpeg() -> String:
	if _ffmpeg == "":
		var out := []
		var windows := OS.get_name() == "Windows"
		OS.execute("where" if windows else "which", ["ffmpeg"], out)
		var found: String = str(out[0]).strip_edges().get_slice("\n", 0).strip_edges() if out.size() else ""
		_ffmpeg = found if found != "" and FileAccess.file_exists(found) else "-"
	return "" if _ffmpeg == "-" else _ffmpeg


func _convert_job(paths: PackedStringArray, fmt: String, ffmpeg: String) -> void:
	var done := 0
	var failed := PackedStringArray()
	for n in paths.size():
		if _job_abort:
			break
		var src := paths[n]
		var ext := src.get_extension().to_lower()
		if ext == fmt or (ext == "jpeg" and fmt == "jpg"):
			continue  # already that format
		var target := src.get_basename() + "." + fmt
		var k := 2
		while FileAccess.file_exists(target):
			target = "%s (%d).%s" % [src.get_basename(), k, fmt]
			k += 1
		var ok := false
		if fmt in IMAGE_OUT:
			var img := Image.new()
			if ext in IMAGE_EXT and img.load(src) == OK:
				match fmt:
					"png": ok = img.save_png(target) == OK
					"jpg": ok = img.save_jpg(target, 0.92) == OK
					"webp": ok = img.save_webp(target, true, 0.9) == OK
		else:
			var args := ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-i", src]
			args.append_array(FFMPEG_ARGS[fmt])
			args.append(target)
			ok = OS.execute(ffmpeg, args) == 0 and FileAccess.file_exists(target)
		if ok:
			done += 1
		else:
			failed.append(src.get_file())
		_job_progress.call_deferred("Converting...  %d / %d" % [n + 1, paths.size()])
	_convert_done.call_deferred(done, failed, fmt)


func _convert_done(done: int, failed: PackedStringArray, fmt: String) -> void:
	_job.wait_to_finish()
	status.text = "Converted %d file%s to %s.%s" % [done, "" if done == 1 else "s", fmt.to_upper(),
		("  Couldn't convert: " + ", ".join(failed)) if not failed.is_empty() else ""]
	if done > 0 and not _roots.is_empty():
		_rescan.start()  # pick the new files up


func _recycle() -> void:
	var recs := _targets()
	if recs.is_empty():
		return
	_ask("Send %d file%s to the Recycle Bin?" % [recs.size(), "" if recs.size() == 1 else "s"], func() -> void:
		var gone := PackedInt32Array()
		for r in recs:
			if OS.move_to_trash(_path[r]) == OK:
				gone.append(r)
		_drop_records(gone)
		status.text = "Sent %d file%s to the Recycle Bin%s" % [gone.size(), "" if gone.size() == 1 else "s",
			"  (%d failed)" % (recs.size() - gone.size()) if gone.size() < recs.size() else ""])


func _ask(text: String, action: Callable) -> void:
	confirm.dialog_text = text
	_confirm_action = action
	confirm.popup_centered()


## Removes records (for files that no longer exist) from every column.
func _drop_records(recs: PackedInt32Array) -> void:
	if recs.is_empty():
		return
	var gone := {}
	for r in recs:
		gone[r] = true
	var keep := _empty_cols()
	for i in _path.size():
		if not gone.has(i):
			for f in FIELDS:
				keep[f].append(get(f)[i])
	_set_records(keep)
	_index_dirty = true
	_rebuild(false)


# --- settings and the file index ---------------------------------------------

## Settings survive restarts: loaded once at start, saved once on exit (any way the app closes).
func _load_prefs() -> void:
	var cf := ConfigFile.new()
	cf.load(PREFS)  # missing file = all defaults
	_font_path = cf.get_value("ui", "font", "")  # before _set_dark, which builds the theme
	_set_dark(cf.get_value("ui", "dark", false))
	_sort = cf.get_value("ui", "sort", "name")
	_desc = cf.get_value("ui", "desc", false)
	_group = cf.get_value("ui", "group", "none")
	_set_columns(cf.get_value("ui", "columns", DEFAULT_COLUMNS.map(func(k: String) -> Array: return [k, COLUMN_DEFS[k][1]])))
	_set_view(cf.get_value("ui", "view", 2))
	_set_numbered(cf.get_value("ui", "numbered", false))
	_sounds = cf.get_value("ui", "sounds", true)  # set quietly: no blip at launch
	_set_preview(cf.get_value("ui", "preview", false))
	_set_exts(cf.get_value("filter", "types", PRESETS.Audio))
	_skips.assign(cf.get_value("filter", "skips", DEFAULT_SKIPS))
	_refresh_skips()
	_roots.assign(cf.get_value("filter", "folders", []))  # kept even if a drive is unplugged right now
	_refresh_folders()
	%Split.split_offset = cf.get_value("ui", "sidebar", 0)
	%Split2.split_offset = cf.get_value("ui", "preview_split", 0)
	var w := get_window()
	w.size = cf.get_value("window", "size", w.size)
	w.content_scale_factor = cf.get_value("window", "zoom", 1.0)
	if cf.get_value("window", "fullscreen", false):
		_toggle_fullscreen.call_deferred()


func _save_prefs() -> void:
	var cf := ConfigFile.new()
	cf.set_value("ui", "dark", P == DARK_PAL)
	cf.set_value("ui", "view", _view)
	cf.set_value("ui", "sort", _sort)
	cf.set_value("ui", "desc", _desc)
	cf.set_value("ui", "group", _group)
	cf.set_value("ui", "columns", fv.columns.map(func(c: Dictionary) -> Array: return [c.key, int(c.width)]))
	cf.set_value("ui", "numbered", _numbered)
	cf.set_value("ui", "sounds", _sounds)
	cf.set_value("ui", "font", _font_path)
	cf.set_value("ui", "preview", %Preview.visible)
	cf.set_value("ui", "sidebar", %Split.split_offset)
	cf.set_value("ui", "preview_split", %Split2.split_offset)
	cf.set_value("filter", "types", _exts)
	cf.set_value("filter", "skips", _skips)
	cf.set_value("filter", "folders", _roots)
	var w := get_window()
	cf.set_value("window", "fullscreen", _fullscreen())
	if not _fullscreen():  # fullscreen picks its own size and scale
		cf.set_value("window", "size", w.size)
		cf.set_value("window", "zoom", w.content_scale_factor)
	cf.save(PREFS)


## The last scan (with sizes, dates and tags), so the next launch shows it instantly.
func _index_key() -> String:
	return str([_roots, _exts, _skips])


func _save_index() -> void:
	var f := FileAccess.open_compressed(INDEX, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f:
		f.store_var({v = 1, key = _index_key(), cols = FIELDS.map(func(k: String) -> Variant: return get(k))})
	_index_dirty = false


func _load_index() -> bool:
	if not FileAccess.file_exists(INDEX):
		return false
	var f := FileAccess.open_compressed(INDEX, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	var d = f.get_var() if f else null
	if not d is Dictionary or d.get("v") != 1 or d.get("key") != _index_key():
		return false  # made for other folders or filters
	for n in FIELDS.size():
		set(FIELDS[n], d.cols[n])
	_rebuild(false)
	_update_status("From last time; checking for changes...")
	return true


func _exit_tree() -> void:
	_video.stop()
	_save_prefs()
	_abort = true
	_job_abort = true
	if _thread.is_started():
		_thread.wait_to_finish()
	if _job.is_started():
		_job.wait_to_finish()
	for id in _thumb_tasks:
		WorkerThreadPool.wait_for_task_completion(id)
	if _index_dirty:
		_save_index()


# --- Win95 theme -------------------------------------------------------------
# StyleBoxFlat has ONE border colour, so it can't do a two-tone bevel.
# Instead: paint a bevel image and nine-slice it with a 2px margin. (16px, not 5: a 1px
# centre smears into a gradient wherever a window renders with linear filtering.)

func _bevel(otl: Color, itl: Color, obr: Color, ibr: Color, fill: Color, w := 16, h := -1) -> Image:
	h = w if h < 0 else h
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(fill)
	for x in w:
		img.set_pixel(x, h - 1, obr); img.set_pixel(x, 0, otl)
		if x > 0 and x < w - 1:
			img.set_pixel(x, h - 2, ibr); img.set_pixel(x, 1, itl)
	for y in h:
		img.set_pixel(w - 1, y, obr); img.set_pixel(0, y, otl)
		if y > 0 and y < h - 1:
			img.set_pixel(w - 2, y, ibr); img.set_pixel(1, y, itl)
	return img


func _box(img: Image, pad := 4) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = ImageTexture.create_from_image(img)
	sb.set_texture_margin_all(2)
	sb.set_content_margin_all(pad)
	return sb


func _flat(c: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	return sb


## Title-bar button glyph: one window (maximise) or two stacked (restore). White, tinted by the theme.
func _frame_icon(maximise: bool) -> ImageTexture:
	var img := Image.create(9, 9, false, Image.FORMAT_RGBA8)
	var rects := [Rect2i(0, 0, 9, 9)] if maximise else [Rect2i(2, 0, 7, 6), Rect2i(0, 3, 7, 6)]
	for r: Rect2i in rects:
		for x in range(r.position.x, r.end.x):
			for y in range(r.position.y, r.end.y):
				var edge := x == r.position.x or x == r.end.x - 1 or y <= r.position.y + 1 or y == r.end.y - 1
				img.set_pixel(x, y, Color.WHITE if edge else Color.TRANSPARENT)
	return ImageTexture.create_from_image(img)


## Status-bar size grip: three lit/shadowed diagonal ridges in the bottom-right corner.
func _grip_icon() -> ImageTexture:
	var img := Image.create(12, 12, false, Image.FORMAT_RGBA8)
	for x in 12:
		for y in 12:
			var d := x + y
			for b in [11, 15, 19]:
				if d == b or d == b + 1:
					img.set_pixel(x, y, P.shade if P == LIGHT_PAL else P.deep)
				elif d == b - 1:
					img.set_pixel(x, y, P.hi)
	return ImageTexture.create_from_image(img)


func _checkbox_icon(checked: bool) -> ImageTexture:
	var img := _bevel(P.shade, P.deep, P.hi, P.lite, P.field, 13)
	if checked:
		# 7px wide, 3px thick tick: down 2, up 4
		var tops := [5, 6, 7, 6, 5, 4, 3]
		for i in tops.size():
			for dy in 3:
				img.set_pixel(3 + i, tops[i] + dy, P.ink)
	return ImageTexture.create_from_image(img)


func _win95_theme() -> Theme:
	var t := Theme.new()
	var font: Font = null
	if _font_path != "" and _is_font(_font_path):  # the user's own font, kept smooth (they chose it to look like itself)
		var ff := FontFile.new()
		if ff.load_dynamic_font(_font_path) == OK:
			font = ff
	var bold: Font
	if font:
		var fv_bold := FontVariation.new()
		fv_bold.base_font = font
		fv_bold.variation_embolden = 0.8
		bold = fv_bold
	else:
		var sf := SystemFont.new()
		sf.font_names = PackedStringArray(["Microsoft Sans Serif", "MS Sans Serif", "Tahoma", "Arial"])
		sf.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		sf.hinting = TextServer.HINTING_NORMAL
		sf.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		font = sf
		var sb := sf.duplicate() as SystemFont
		sb.font_weight = 700
		bold = sb
	t.default_font = font
	t.default_font_size = 11

	var raised := _box(_bevel(P.lite, P.hi, P.deep, P.shade, P.face))
	var pushed := _box(_bevel(P.deep, P.shade, P.hi, P.lite, P.face))
	var field := _box(_bevel(P.shade, P.deep, P.hi, P.lite, P.field), 3)
	var none := StyleBoxEmpty.new()

	t.set_stylebox("panel", "Panel", raised)
	t.set_stylebox("panel", "PanelContainer", raised)
	t.set_color("font_color", "Label", P.ink)
	t.set_type_variation("SectionLabel", "Label")
	t.set_font("font", "SectionLabel", bold)
	t.set_type_variation("Sunken", "PanelContainer")
	t.set_stylebox("panel", "Sunken", _box(_bevel(P.shade, P.deep, P.hi, P.lite, P.field), 6))
	t.set_type_variation("StatusBar", "PanelContainer")
	t.set_stylebox("panel", "StatusBar", _box(_bevel(P.shade, P.face, P.hi, P.face, P.face), 3))

	for type in ["Button", "OptionButton", "MenuButton", "LinkButton"]:
		for s in ["normal", "hover", "disabled"]:
			t.set_stylebox(s, type, raised)
		for s in ["pressed", "hover_pressed"]:  # also the "on" look of toggle buttons
			t.set_stylebox(s, type, pushed)
		t.set_stylebox("focus", type, none)
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
			t.set_color(c, type, P.ink)
		t.set_color("font_disabled_color", type, P.dim)
		for c in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color", "icon_hover_pressed_color"]:
			t.set_color(c, type, P.ink)  # built-in dialog icons are white; tint them to the text colour
		t.set_color("icon_disabled_color", type, P.dim)
	for c in ["font_color", "font_hover_color", "font_pressed_color"]:
		t.set_color(c, "LinkButton", P.sel if P == LIGHT_PAL else P.sel.lightened(0.5))

	for type in ["LineEdit", "TextEdit"]:
		for s in ["normal", "read_only"]:
			t.set_stylebox(s, type, field)
		t.set_stylebox("focus", type, none)
		for c in ["font_color", "font_readonly_color", "caret_color"]:
			t.set_color(c, type, P.ink)
		t.set_color("font_placeholder_color", type, P.dim)
		t.set_color("selection_color", type, P.sel)
		t.set_color("font_selected_color", type, P.sel_ink)
	t.set_color("background_color", "TextEdit", P.field)

	t.set_stylebox("panel", "ItemList", field)
	t.set_stylebox("selected", "ItemList", _flat(P.sel))
	t.set_color("font_color", "ItemList", P.ink)
	t.set_color("font_selected_color", "ItemList", P.sel_ink)

	for type in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", type, _flat(P.lite))
		t.set_stylebox("scroll_focus", type, _flat(P.lite))
		for s in ["grabber", "grabber_highlight", "grabber_pressed"]:
			t.set_stylebox(s, type, _box(_bevel(P.lite, P.hi, P.deep, P.shade, P.face), 7))

	var slider := _box(_bevel(P.shade, P.deep, P.hi, P.lite, P.field), 2)
	t.set_stylebox("slider", "HSlider", slider)
	t.set_stylebox("grabber_area", "HSlider", _flat(P.sel))
	t.set_stylebox("grabber_area_highlight", "HSlider", _flat(P.sel))
	var thumb := ImageTexture.create_from_image(_bevel(P.lite, P.hi, P.deep, P.shade, P.face, 11, 19))
	for s in ["grabber", "grabber_highlight", "grabber_disabled"]:
		t.set_icon(s, "HSlider", thumb)

	var blank := ImageTexture.create_from_image(Image.create(1, 1, false, Image.FORMAT_RGBA8))
	t.set_icon("grabber", "HSplitContainer", blank)
	t.set_constant("separation", "HSplitContainer", 6)
	var line := StyleBoxLine.new()
	line.color = P.shade
	t.set_stylebox("separator", "HSeparator", line)

	t.set_stylebox("panel", "PopupMenu", raised)
	t.set_stylebox("hover", "PopupMenu", _flat(P.sel))
	t.set_color("font_color", "PopupMenu", P.ink)
	t.set_color("font_hover_color", "PopupMenu", P.sel_ink)
	t.set_color("font_disabled_color", "PopupMenu", P.dim)
	t.set_color("font_accelerator_color", "PopupMenu", P.dim)
	t.set_color("font_separator_color", "PopupMenu", P.dim)
	for pair in [["checked", true], ["unchecked", false], ["radio_checked", true], ["radio_unchecked", false]]:
		t.set_icon(pair[0], "PopupMenu", _checkbox_icon(pair[1]))
	var tip := _flat(Color("ffffe1"))  # the classic yellow tooltip
	tip.set_border_width_all(1)
	tip.border_color = Color.BLACK
	tip.set_content_margin_all(3)
	t.set_stylebox("panel", "TooltipPanel", tip)
	t.set_color("font_color", "TooltipLabel", Color.BLACK)

	# Embedded windows (dialogs, and the FileDialog fallback): navy title, raised body.
	var frame := _flat(Color("000080"))
	frame.set_expand_margin_all(3)
	frame.expand_margin_top = 20
	t.set_stylebox("embedded_border", "Window", frame)
	t.set_stylebox("embedded_unfocused_border", "Window", frame)
	t.set_color("title_color", "Window", Color.WHITE)
	t.set_constant("title_height", "Window", 18)
	t.set_stylebox("panel", "AcceptDialog", raised)
	t.set_color("folder_icon_color", "FileDialog", P.sel)
	t.set_color("file_icon_color", "FileDialog", P.ink)
	t.set_color("file_disabled_color", "FileDialog", P.dim)
	return t
