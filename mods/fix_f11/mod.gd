extends RefCounted
## Модификация «Фикс F11 (Полный экран)»
## Автор: @good_boy_irl
##
## Перехватывает F11 и Alt+Enter на уровне _input с гарантированным дебаунсом,
## исключая двойные срабатывания и мгновенный возврат в оконный режим.

var _mod_id: String = "fix_f11"
var _handler_node: Node = null

class F11InputHandler extends Node:
	var last_toggle: int = 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _input(event: InputEvent) -> void:
		if event is InputEventKey and event.pressed and not event.echo:
			if event.keycode == KEY_F11 or (event.keycode == KEY_ENTER and event.alt_pressed):
				get_viewport().set_input_as_handled()
				var now: int = Time.get_ticks_msec()
				if now - last_toggle < 350:
					return
				last_toggle = now
				var cur: int = DisplayServer.window_get_mode()
				if cur == DisplayServer.WINDOW_MODE_FULLSCREEN or cur == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
					DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
					print("[FixF11] Window mode set to WINDOWED")
				else:
					DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
					print("[FixF11] Window mode set to FULLSCREEN")

func init_mod(mod_mgr: Node) -> void:
	print("[FixF11] Initializing F11 Fullscreen Fix Mod...")
	if _handler_node == null:
		_handler_node = F11InputHandler.new()
		_handler_node.name = "F11InputHandler"
		if mod_mgr != null:
			mod_mgr.add_child(_handler_node)
		else:
			var loop = Engine.get_main_loop()
			if loop and "root" in loop and loop.root:
				loop.root.add_child(_handler_node)
	print("[FixF11] F11 Input Handler active!")

func cleanup_mod(_mod_mgr: Node) -> void:
	print("[FixF11] Cleaning up F11 Fullscreen Fix Mod...")
	if _handler_node != null and is_instance_valid(_handler_node):
		_handler_node.queue_free()
		_handler_node = null
