# NetworkManager.gd
extends Node
# class_name NetworkManager
class_name NetworkManager
# —— Signals for UI & Main to hook into ——
signal connected_to_host()
signal connection_failed()
signal disconnected_from_host()
signal player_joined(id)
signal player_left(id)
signal game_started()
signal dice_rolled(player_id: int, rolls: PackedInt32Array)
signal bid_made(player_id: int, face: int, quantity: int)
signal bluff_called(caller_id: int)
signal hosting_started(info: Dictionary)
signal code_generated(code: String)

# —— Configuration constants ——
const DEFAULT_PORT := 42069
const MAX_PLAYERS  := 2
const DISCOVERY_PORT := 42100
const DISCOVERY_INTERVAL := 0.5   # seconds

var _peer: ENetMultiplayerPeer
var _port: int = 0
var _max_clients: int = 2
var _current_code: String = ""
var _ad_udp: PacketPeerUDP = null
var _ad_timer: Timer = null

# —— Public API ——
func host_lobby(port: int = DEFAULT_PORT, max_clients: int = MAX_PLAYERS) -> void:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, max_clients)
	if err != OK:
		push_error("Failed to host on port %d (err %d)" % [port, err])
		return

	_port = port
	_max_clients = max_clients

	get_tree().get_multiplayer().multiplayer_peer = _peer
	_connect_mp_signals()
	# _hook_peer_signals(_peer)
	print("Hosting on port %d" % port)

	var code := begin_random_lobby(6) # or 8 if you want longer
	print("Random Join Code:", code)
	
	# Build & broadcast host info
	var info := get_lobby_info()
	print_lobby_info(info)
	emit_signal("hosting_started", info)

func get_current_port() -> int:
	# Use the real port once host_lobby()/join_lobby() set it
	return _port if _port > 0 else DEFAULT_PORT
	
	
func _join_button_pressed(address: String, port: int = DEFAULT_PORT) -> void:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(address, port)
	if err != OK:
		push_error("Failed to connect to %s:%d (err %d)" % [address, port, err])
		return

	_port = port
	_max_clients = MAX_PLAYERS

	get_tree().get_multiplayer().multiplayer_peer = _peer
	_connect_mp_signals()
	# Hook up connect/disconnect
	# _hook_peer_signals(_peer)

	# Built-in connection signals (Callable form)
	# _peer.connection_succeeded.connect(Callable(self, "_on_connection_succeeded"))
	# _peer.connection_failed.connect(Callable(self, "_on_connection_failed"))
	# _peer.server_disconnected.connect(Callable(self, "_on_server_disconnected"))


var _mp_signals_hooked := false

func _connect_mp_signals() -> void:
	if _mp_signals_hooked:
		return
	var mp := get_tree().get_multiplayer()
	mp.connected_to_server.connect(Callable(self, "_on_connection_succeeded"))
	mp.connection_failed.connect(Callable(self, "_on_connection_failed"))
	mp.server_disconnected.connect(Callable(self, "_on_server_disconnected"))
	mp.peer_connected.connect(Callable(self, "_on_peer_connected"))
	mp.peer_disconnected.connect(Callable(self, "_on_peer_disconnected"))
	_mp_signals_hooked = true


# —— Internal peer hookup ——
func _hook_peer_signals(peer: ENetMultiplayerPeer) -> void:
	peer.peer_connected.connect(Callable(self, "_on_peer_connected"))
	peer.peer_disconnected.connect(Callable(self, "_on_peer_disconnected"))

# —— Peer callbacks ——    
func _on_connection_succeeded():
	emit_signal("connected_to_host")

func _on_connection_failed():
	emit_signal("connection_failed")

func _on_server_disconnected():
	emit_signal("disconnected_from_host")

func _on_peer_connected(id: int):
	emit_signal("player_joined", id)

func _on_peer_disconnected(id: int):
	emit_signal("player_left", id)

# —— RPC methods ——
@rpc("any_peer")
func rpc_start_game():
	emit_signal("game_started")

@rpc("any_peer")
func rpc_roll_dice(rolls: PackedInt32Array):
	emit_signal("dice_rolled", get_tree().get_multiplayer().get_unique_id(), rolls)

@rpc("any_peer")
func rpc_make_bid(face: int, quantity: int):
	emit_signal("bid_made", get_tree().get_multiplayer().get_unique_id(), face, quantity)

@rpc("any_peer")
func rpc_call_bluff():
	emit_signal("bluff_called", get_tree().get_multiplayer().get_unique_id())

# —— Helper calls for UI/Game logic to broadcast ——
func start_game():
	# only host should call this
	rpc_id(0, "rpc_start_game")

func roll_dice(rolls: PackedInt32Array):
	rpc_id(0, "rpc_roll_dice", rolls)

func make_bid(face: int, quantity: int):
	rpc_id(0, "rpc_make_bid", face, quantity)

func call_bluff():
	rpc_id(0, "rpc_call_bluff")

# =========================
# Join-code helpers (Base32)
# =========================

const CODE_ALPHABET := "0123456789ABCDEFGHJKMNPQRSTVWXYZ" # Crockford-ish, no I L O U

func _private_ipv4() -> String:
	var addrs := IP.get_local_addresses()
	# Prefer private IPv4 (10.x, 172.16-31.x, 192.168.x)
	for a in addrs:
		if a.find(":") == -1 and not a.begins_with("127."):
			var parts := a.split(".")
			if parts.size() == 4:
				var A := int(parts[0])
				var B := int(parts[1])
				if A == 10: return a
				if A == 192 and B == 168: return a
				if A == 172 and B >= 16 and B <= 31: return a
	# Fallback to any non-loopback IPv4
	for a in addrs:
		if a.find(":") == -1 and not a.begins_with("127."):
			return a
	return "0.0.0.0"

func get_lobby_info() -> Dictionary:
	var mp: MultiplayerAPI = get_tree().get_multiplayer()

	var status_names: Array[String] = ["disconnected", "connecting", "connected"]

	var peer := mp.get_multiplayer_peer()
	var status_idx: int = 0
	if peer != null:
		status_idx = peer.get_connection_status()  # on the ENetMultiplayerPeer

	var ips: PackedStringArray = PackedStringArray()
	for a in IP.get_local_addresses():
		if a.find(":") == -1 and not a.begins_with("127."):
			ips.append(a)

	var status_str: String = status_names[min(status_idx, status_names.size() - 1)]

	return {
		"peer_id": mp.get_unique_id(),
		"is_server": mp.is_server(),
		"status": status_str,
		"port": _port,
		"max_clients": _max_clients,
		"lan_ips": ips
	}



func print_lobby_info(info: Dictionary) -> void:
	var ips: PackedStringArray = info.get("lan_ips", PackedStringArray())
	var ips_str := (", ".join(ips)) if ips.size() > 0 else "(no LAN IPv4 found)"
	print("\n--- Lobby Hosting ---")
	print(" Status:     ", info.get("status", ""))
	print(" Is Server:  ", info.get("is_server", false))
	print(" Peer ID:    ", info.get("peer_id", -1))
	print(" Port:       ", info.get("port", -1))
	print(" Max clients:", info.get("max_clients", -1))
	print(" LAN IPs:    ", ips_str)
	print("---------------------\n")

# --------- Public helpers: code <-> ip:port ----------
func generate_random_code(code_len: int = 6) -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var s := ""
	for i in range(code_len):
		s += CODE_ALPHABET[rng.randi_range(0, CODE_ALPHABET.length() - 1)]
	return s

func begin_random_lobby(code_len: int = 6) -> String:
	# call this *after* host_lobby() succeeds
	_current_code = generate_random_code(code_len)
	_start_lan_advertising()
	emit_signal("code_generated", _current_code)
	return _current_code

func get_current_code() -> String:
	return _current_code

func _start_lan_advertising() -> void:
	if _ad_udp == null:
		_ad_udp = PacketPeerUDP.new()
		_ad_udp.set_broadcast_enabled(true)
		# set default broadcast dest
		var err := _ad_udp.connect_to_host("255.255.255.255", DISCOVERY_PORT)
		if err != OK:
			push_error("LAN advertise connect_to_host failed: %s" % err)
			return
	if _ad_timer == null:
		_ad_timer = Timer.new()
		_ad_timer.wait_time = DISCOVERY_INTERVAL
		_ad_timer.one_shot = false
		add_child(_ad_timer)
		_ad_timer.timeout.connect(Callable(self, "_on__advertise_tick"))
	if _ad_timer.is_stopped():
		_ad_timer.start()

func _on__advertise_tick() -> void:
	if _ad_udp == null or _current_code == "":
		return
	var payload := {
		"code": _current_code,
		"ip": _private_ipv4(),
		"port": _port
	}
	var bytes: PackedByteArray = JSON.stringify(payload).to_utf8_buffer()
	var err := _ad_udp.put_packet(bytes)
	if err != OK:
		# harmless if it occasionally fails on some NICs
		pass

func stop_random_lobby_advertising() -> void:
	if _ad_timer:
		_ad_timer.stop()
	if _ad_udp:
		_ad_udp.close()
		_ad_udp = null

# Listen on LAN for a host with this code; returns OK or ERR_TIMEOUT.
# On success it automatically calls join_lobby() for you.
func join_via_random_code(code: String, timeout_sec: float = 3.0) -> int:
	var listener := PacketPeerUDP.new()
	var err := listener.bind(DISCOVERY_PORT)
	if err != OK:
		push_error("Discovery bind failed on %d (err %d)" % [DISCOVERY_PORT, err])
		return err

	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		while listener.get_available_packet_count() > 0:
			var pkt: PackedByteArray = listener.get_packet()
			var txt := pkt.get_string_from_utf8()
			var d = JSON.parse_string(txt)
			if typeof(d) == TYPE_DICTIONARY and d.has("code") and String(d["code"]) == code:
				var ip := String(d.get("ip", ""))
				var port := int(d.get("port", DEFAULT_PORT))
				listener.close()
				join_lobby(ip, port)
				return OK
		await get_tree().process_frame
	listener.close()
	return ERR_TIMEOUT
pass
