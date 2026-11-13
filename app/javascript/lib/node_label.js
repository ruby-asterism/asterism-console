// The graph's label of a node (console_controller's nodeElement), apart so
// that the tests run it under Node (test/lib/node_label_test.rb).
//
// A name goes before the ID, the ID in parentheses ("Tab5 (fmruby-aaaaaa)"):
// calls, permissions and the registry use the ID, so it stays in the label.
// The name is the registry's display name (0.3.5, an admin's, data "peer"
// "display_name"), else the name the node's profile told (G1b, Asterism
// nodes only), else none. This console itself is "<ID> (this console)", and
// a room's game host "<ID> (room NN)" (0.3.3): the rooms' nodes are not the
// registry's, and their labels stay as they are.
//
// An Asterism app whose token says another protocol than the console's
// (data "other_protocol", Bridge::Graph) is "<app> (protocol N)".
export function nodeLabel(n) {
  const data = n.data || {}
  if (data.self) return `${n.label} (this console)`
  if (n.kind === "a_app" && data.other_protocol) return `${n.label} (protocol ${data.protocol})`
  if (n.kind === "a_node" && data.room_host && data.room) return `${n.label} (room ${data.room})`
  if (!["a_node", "router", "registered"].includes(n.kind)) return n.label
  const shown = data.peer?.display_name || (n.kind === "a_node" ? data.profile?.name : null)
  return shown && shown !== n.label ? `${shown} (${n.label})` : n.label
}
