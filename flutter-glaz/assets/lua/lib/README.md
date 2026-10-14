# Frame standard Lua libraries

`data.min.lua` and `camera.min.lua` from the Python `frame-msg` 5.2.1
package (`frame_msg/lua/`), the versions `../../../../host_test.py` uploads
and the app is tested with. The Dart `frame_msg` 2.0.0 ships an older
`data.min.lua` without the per-packet acknowledgements, so these are copied
here rather than taken from it. Glaz uploads them next to the modules.
