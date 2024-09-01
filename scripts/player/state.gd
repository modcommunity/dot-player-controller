extends Resource
class_name Player_State

var ply : Player

var initial_states = ["run"]

var states = {}
var active = []

func setup():
	# Load and initialize our available states.
	init_state("run")
	init_state("air")
	
	init_state("crouch")
	
	init_state("sprint")
	init_state("walk")
	
	# Add initial states to active list.
	active.append_array(initial_states)
	
	# Activate initial states.
	for state in initial_states:
		states[state].activate()
	
func init_state(name):
	var base_dir = get_script().resource_path.get_base_dir()
	
	states[name] = load(base_dir + "/states/" + name + ".gd").new()
	
	# Assign ply.
	states[name].ply = ply

func add_state(name, data = {}):
	if name not in states:
		return
		
	if name not in active:
		# Add state to list of active states.
		active.append(name)
		
		# Call activate.
		states[name].activate(data)
		
func del_state(name, data = {}):
	if name not in states:
		return
		
	if name in active:
		# Remove state from active states.
		active.erase(name)
		
		# Call deactivate.
		states[name].deactivate(data)
		
func swap_state(old, new, old_data = {}, new_data = {}):
	if new not in states:
		return
	
	# Remove old state.
	del_state(old, old_data)
	
	# Add new state.
	add_state(new, new_data)
	
func has_state(name):
	if name in active:
		return true
		
	return false

func _physics_process(delta):
	# Execute active states.
	for state in active:
		states[state]._physics_process(delta)
		
func _process(delta):
	# Execute active states.
	for state in active:
		states[state]._process(delta)
