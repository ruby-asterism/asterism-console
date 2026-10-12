# G1b: one connection per application, display names in the graph

Stage G1b (asterism 0.6.0). Done 2026-10-12, checked against the Linux
sim (othello, the rover brain with the MuJoCo rover), boards and the
browser build.

asterism 0.6.0 adds `Asterism.session`: an application puts, subscribes
and runs its ROS 2 node on the object layer's own Zenoh session instead of
opening a second one. Two things follow for the console.

## A ROS 2 node inside its Asterism node

A ROS 2 node on the same session as an Asterism node (a board's rover
brain: the object `<node>/brain/rover` and the ROS 2 node
`/fmruby_brain_<node>` on one connection) is drawn **inside that Asterism
node's box**, next to its apps.

- Rule (`Bridge::Connections`): a session that carries exactly one
  Asterism node and some ROS 2 nodes makes those ROS 2 nodes children of
  the Asterism node (data `in_node`). They get no line of their own to the
  router; the Asterism node's line stands for the session. Their topic
  arrows are drawn as before.
- They are not folded into a machine (`Bridge::Groups` leaves them out):
  the Asterism node already says which machine they are on.
- A ROS 2 node on a session of its own (the 0.5.x way, two sessions; any
  plain ROS 2 process) stays outside, as before.
- Recordings: the rewind derives the drawing again, so recordings of the
  structure made before G1b show the nesting too when the sessions match.

## Display names

A node's profile may carry a display name (`name`; Family mruby keeps the
player's name in `/home/asterism_profile.toml` and sets it in every
application). The graph's label is now `<name> (<node ID>)` when the
profile has a name, and the ID alone otherwise. The ID stays in the label
because calls, Call permissions and the relay registry use it. A change of
name shows within a second (the profile notice on
`asterism/<node>/@profile`, V2.5).

## One-time passes

Nothing changed at the door (`bin/ws_door`, `/passes/check`): a pass still
lets one connection in. The applications that used to open two
(othello, rt_probe, rover_pilot) now open one, so they get in with one pass.
