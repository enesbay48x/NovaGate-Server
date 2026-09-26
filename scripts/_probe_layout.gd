extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var err := change_scene_to_file("res://scenes/main.tscn")
	if err != OK:
		print("[probe] FAILED to load main scene")
		quit(1)
		return
	await scene_changed
	for unused in range(6):
		await process_frame
	var menu: Node = get_first_node_in_group("menu_ui")
	if menu == null:
		print("[probe] menu_ui node not found")
		quit(1)
		return
	if not menu.has_method("open_skill_tree"):
		print("[probe] open_skill_tree missing")
		quit(1)
		return

	# 1) acilis
	menu.call("open_skill_tree", false)
	for unused in range(4):
		await process_frame
	_dump("acilis")

	# 2) baska bolume git, geri don (eski node'lar silinmeli)
	menu.call("_show_section", "AYARLAR")
	for unused in range(3):
		await process_frame
	menu.call("open_skill_tree", false)
	for unused in range(4):
		await process_frame
	_dump("geri-donus")

	# 3) async yenileme sonrasi
	menu.call("open_skill_tree", true)
	await create_timer(1.2).timeout
	for unused in range(4):
		await process_frame
	_dump("async-sonrasi")

	# 4) MARKET (mevcut pazar baglantisi) testi
	menu.call("_show_section", "MARKET")
	for unused in range(6):
		await process_frame
	var host: Control = menu.get("market_host")
	var inst: Node = menu.get("market_instance")
	print("[probe] MARKET host=", (host != null), " host_visible=", (host.visible if host != null else "null"),
		" instance_ok=", (inst != null and is_instance_valid(inst)),
		" inst_children=", (inst.get_child_count() if (inst != null and is_instance_valid(inst)) else -1))
	if inst != null and is_instance_valid(inst):
		print("[probe] MARKET inst class=", inst.get_class(), " size=", (inst.size if inst is Control else Vector2()))
		var top = null
		for c in inst.get_children():
			if top == null:
				top = c
		print("[probe] MARKET first child=", (top.name if top != null else "none"))

	print("[probe] COMPLETE")
	quit(0)

func _dump(tag: String) -> void:
	var canvas: Node = _find_canvas()
	if canvas == null:
		print("[probe] ", tag, ": SkillTreeCanvas YOK")
		return
	var container: Control = canvas.get_parent()
	var scroll: Control = container.get_parent()
	var panel: Control = container.get_parent().get_parent() if container.get_parent() != null else null
	print("[probe] ", tag, " container=", container.name, " csize=", container.size,
		" canvas.size=", canvas.size, " scroll.size=", scroll.size,
		" content_panel=", _pnl_size(panel))
	var cards := 0
	var ok_size := 0
	var overlaps := 0
	var rects: Array = []
	for c in canvas.get_children():
		if c.name.begins_with("Skillnode_"):
			cards += 1
			var cc: Control = c
			rects.append(Rect2(cc.position, cc.size))
			if cc.size.x >= 260.0 and cc.size.x <= 280.0 and cc.size.y >= 120.0 and cc.size.y <= 140.0:
				ok_size += 1
	for i in range(rects.size()):
		for j in range(i + 1, rects.size()):
			if rects[i].intersects(rects[j]):
				overlaps += 1
	var title: Control = canvas.find_child("SkillTreeTop", true, false)
	print("[probe] ", tag, " cards=", cards, " goodSize=", ok_size,
		" overlappingPairs=", overlaps, " titleVisible=", (title.visible if title != null else false))
	for c in canvas.get_children():
		if c.name.begins_with("Skillnode_"):
			print("[probe]   ", c.name, " pos=", c.position, " size=", c.size)

func _find_canvas() -> Node:
	var menu: Node = get_first_node_in_group("menu_ui")
	if menu == null:
		return null
	return menu.find_child("SkillTreeCanvas", true, false)

func _pnl_size(p) -> String:
	if p == null or not is_instance_valid(p):
		return "null"
	return str(p.size)
