/* Stands in for the firmware's source/application/luaport.h, which the
 * firmware's luaconf.h includes: there it routes print() to Bluetooth.
 * Nothing here changes how Lua compiles; see tool/luac_frame.c. */
#pragma once
#include "lua.h"
